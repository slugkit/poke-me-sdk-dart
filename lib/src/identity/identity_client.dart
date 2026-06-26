import '../api/api_types.dart';
import '../api/byoa_api_types.dart';
import '../api/poke_api_client.dart';
import '../push_token_service.dart';
import '../store/message_store.dart';

/// High-level BYOA orchestrator: turns a client key into a registered,
/// identified device without the caller threading the device singletons
/// (`device_id`, `device_token`) by hand.
///
/// Combines [PushTokenService] (platform push token), [PokeApiClient] (HTTP),
/// and [MessageStore] (which persists the device id/token in `sync_state`).
/// This is the identity/unicast counterpart to the channel-axis `Subscriber`.
///
/// Typical lifecycle:
/// ```dart
/// await identity.registerOnLaunch();    // anonymous install → dt_ persisted
/// await identity.identify(userId);       // bind to the developer's user id
/// // … later …
/// await identity.unidentify();           // on logout
/// ```
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

  /// Ensures the install is registered. Idempotent — safe to call on every
  /// launch:
  /// - first run: registers via the client key, persisting `device_id` and
  ///   the device token;
  /// - subsequent runs: the device token already exists, so this just pushes
  ///   the (possibly rotated) platform push token up.
  ///
  /// Throws [PokeApiException] on HTTP/transport errors and
  /// [PushTokenException] if the platform refuses to issue a push token.
  Future<void> registerOnLaunch() async {
    final pushToken = await _tokenService.getToken();

    final existingToken = await _store.getDeviceToken();
    if (existingToken != null) {
      await _api.updatePushToken(
        deviceToken: existingToken,
        request: UpdatePushTokenRequest(
          platform: _platform,
          pushToken: pushToken.token,
        ),
      );
      return;
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
  }

  /// Binds this device to [externalUserId] (the developer's opaque end-user
  /// id), creating the subject on first use. Idempotent server-side; returns
  /// the subject id.
  ///
  /// Throws [StateError] if the device has not been registered yet — call
  /// [registerOnLaunch] first.
  Future<String> identify(String externalUserId) async {
    final deviceToken = await _requireDeviceToken();
    final response = await _api.identify(
      deviceToken: deviceToken,
      request: IdentifyRequest(
        appId: _appId,
        externalUserId: externalUserId,
        apnsEnvironment: _apnsEnvironment,
      ),
    );
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
