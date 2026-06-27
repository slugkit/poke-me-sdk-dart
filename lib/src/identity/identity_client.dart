import '../api/api_exception.dart';
import '../api/api_types.dart';
import '../api/byoa_api_types.dart';
import '../api/poke_api_client.dart';
import '../push_token_service.dart';
import '../store/message_store.dart';

/// Outcome of [IdentityClient.registerOnLaunch] / [IdentityClient.ensureRegistered].
///
/// Lets callers distinguish "registered with the server" from "did nothing
/// because permission wasn't granted" — both of which used to return `void`.
enum RegistrationStatus {
  /// Newly registered with the server; `device_id` / device token persisted.
  registered,

  /// Already registered; the (possibly rotated) platform push token was
  /// pushed up to the server.
  refreshed,

  /// `requestPermission` was false and notification permission has not been
  /// granted yet — nothing was sent. The device stays unregistered until a
  /// later call at a contextual moment.
  permissionDeferred,

  /// [IdentityClient.ensureRegistered] only: the server already has a live
  /// push token for this device — nothing to do.
  alreadyCurrent,
}

/// High-level BYOA orchestrator: turns a client key into a registered,
/// identified device without the caller threading the device singletons
/// (`device_id`, `device_token`) by hand.
///
/// Combines [PushTokenService] (platform push token), [PokeApiClient] (HTTP),
/// and [MessageStore] (which persists the device id/token in `sync_state`).
/// This is the identity/unicast counterpart to the channel-axis `Subscriber`.
class IdentityClient {
  IdentityClient({
    required PushTokenService tokenService,
    required PokeApiClient apiClient,
    required MessageStore store,
    required DevicePlatform platform,
    required String appId,
    required String clientKey,
    ApnsEnvironment? apnsEnvironment,
  })  : _tokenService = tokenService,
        _api = apiClient,
        _store = store,
        _platform = platform,
        _appId = appId,
        _clientKey = clientKey,
        _apnsEnvironment = apnsEnvironment;

  final PushTokenService _tokenService;
  final PokeApiClient _api;
  final MessageStore _store;
  final DevicePlatform _platform;
  final String _appId;
  final String _clientKey;
  final ApnsEnvironment? _apnsEnvironment;

  String? _currentPushToken;
  ApnsEnvironment? _lastSentApnsEnvironment;

  /// The most recent platform push token the SDK obtained (APNs/FCM), or null
  /// if it hasn't fetched one this session. Diagnostic.
  String? get currentPushToken => _currentPushToken;

  /// Ensures the install is registered. Idempotent — safe to call on every
  /// launch:
  /// - first run: registers via the client key, persisting `device_id` and
  ///   the device token ([RegistrationStatus.registered]);
  /// - subsequent runs: pushes the (possibly rotated) platform push token up
  ///   ([RegistrationStatus.refreshed]).
  ///
  /// [requestPermission] is forwarded to [PushTokenService.getToken]. Pass
  /// false to register **without** showing the OS notification prompt: if
  /// permission hasn't been granted yet this returns
  /// [RegistrationStatus.permissionDeferred] (the device stays unregistered
  /// until a later call at a contextual moment).
  ///
  /// Throws [PokeApiException] on HTTP/transport errors. Throws
  /// [PushTokenException] for platform push-token failures — except a
  /// missing/denied permission when [requestPermission] is false, which yields
  /// [RegistrationStatus.permissionDeferred].
  Future<RegistrationStatus> registerOnLaunch(
      {bool requestPermission = true}) async {
    final PushTokenResult pushToken;
    try {
      pushToken = await _tokenService.getToken(
        requestPermission: requestPermission,
      );
    } on PushTokenException catch (e) {
      if (!requestPermission && e.isPermissionDenied) {
        return RegistrationStatus.permissionDeferred;
      }
      rethrow;
    }
    _currentPushToken = pushToken.token;

    final existingToken = await _store.getDeviceToken();
    if (existingToken != null) {
      await _api.updatePushToken(
        deviceToken: existingToken,
        request: UpdatePushTokenRequest(
          platform: _platform,
          pushToken: pushToken.token,
        ),
      );
      return RegistrationStatus.refreshed;
    }

    final response = await _api.registerDevice(
      appId: _appId,
      clientKey: _clientKey,
      request: RegisterDeviceRequest(
        platform: _platform,
        pushToken: pushToken.token,
        deviceId: await _store.getDeviceId(),
      ),
    );
    await _store.setDeviceCredentials(
      deviceId: response.deviceId,
      deviceToken: response.deviceToken,
    );
    return RegistrationStatus.registered;
  }

  /// Recovers from a server-side cascade-revoke (the fanout worker nulls a
  /// device's push token after repeated push failures, with no signal back).
  ///
  /// Reads `GET /api/v1/devices/me`; if the server has no push token for this
  /// device (revoked), or the device row is gone (404), re-registers. Returns
  /// [RegistrationStatus.alreadyCurrent] when the server already has a live
  /// token. Safe to call on resume / periodically.
  Future<RegistrationStatus> ensureRegistered(
      {bool requestPermission = true}) async {
    final deviceToken = await _store.getDeviceToken();
    if (deviceToken == null) {
      return registerOnLaunch(requestPermission: requestPermission);
    }

    final String? serverToken;
    try {
      serverToken = await _api.fetchDevicePushToken(deviceToken);
    } on PokeApiException catch (e) {
      if (e.statusCode == 404) {
        // Device row gone — start over.
        await _store.clearDeviceCredentials();
        return registerOnLaunch(requestPermission: requestPermission);
      }
      rethrow;
    }

    if (serverToken == null || serverToken.isEmpty) {
      // Cascade-revoked — push a fresh token up (registerOnLaunch will hit the
      // existing-token refresh path).
      return registerOnLaunch(requestPermission: requestPermission);
    }
    return RegistrationStatus.alreadyCurrent;
  }

  /// Binds this device to [externalUserId] (the developer's opaque end-user
  /// id), creating the subject on first use. Idempotent server-side; returns
  /// the subject id.
  ///
  /// [apnsEnvironment] overrides the value configured at construction for this
  /// call. The APNs environment is only sent when it has changed since the
  /// last identify (it persists on the device row server-side), so repeated
  /// identifies don't clobber a manually-corrected value.
  ///
  /// Throws [StateError] if the device has not been registered yet — call
  /// [registerOnLaunch] first.
  Future<String> identify(
    String externalUserId, {
    ApnsEnvironment? apnsEnvironment,
  }) async {
    final deviceToken = await _requireDeviceToken();
    final env = apnsEnvironment ?? _apnsEnvironment;
    final sendEnv = env != null && env != _lastSentApnsEnvironment;
    final response = await _api.identify(
      deviceToken: deviceToken,
      request: IdentifyRequest(
        externalUserId: externalUserId,
        apnsEnvironment: sendEnv ? env : null,
      ),
    );
    if (sendEnv) _lastSentApnsEnvironment = env;
    return response.subjectId;
  }

  /// Clears the device→subject binding (logout). No-op if the device has
  /// never registered.
  Future<void> unidentify() async {
    final deviceToken = await _store.getDeviceToken();
    if (deviceToken == null) return;
    await _api.unidentify(deviceToken: deviceToken);
  }

  /// Pushes a refreshed platform push token to the backend. No-op if the
  /// device has never registered.
  Future<void> refreshPushToken(PushTokenResult pushToken) async {
    _currentPushToken = pushToken.token;
    final deviceToken = await _store.getDeviceToken();
    if (deviceToken == null) return;
    await _api.updatePushToken(
      deviceToken: deviceToken,
      request: UpdatePushTokenRequest(
        platform: _platform,
        pushToken: pushToken.token,
      ),
    );
  }

  Future<String> _requireDeviceToken() async {
    final deviceToken = await _store.getDeviceToken();
    if (deviceToken == null) {
      throw StateError(
        'Device not registered; call registerOnLaunch() before identify().',
      );
    }
    return deviceToken;
  }
}
