import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart' show DatabaseFactory;

import 'api/api_types.dart';
import 'api/byoa_api_types.dart';
import 'api/poke_api_client.dart';
import 'identity/identity_client.dart';
import 'poke_error.dart';
import 'push_token_service.dart';
import 'receiver/push_payload.dart';
import 'receiver/push_service.dart';
import 'store/message_store.dart';

/// Top-level entry point for a BYOA consumer (e.g. a host app embedding the
/// SDK to receive unicast pushes addressed to its own users).
///
/// [init] wires the HTTP client, the platform push-token service, and the
/// local store, and exposes the BYOA lifecycle as a small set of forwarding
/// methods. Hold a single instance for the app's lifetime and [close] it on
/// shutdown.
///
/// ```dart
/// final poke = await PokeMe.init(
///   baseUrl: Uri.parse('https://api.poke-me.io'),
///   appId: '019d8000-0a00-7000-8000-000000000001',
///   clientKey: 'ck_…',            // shipped in the binary, like a Firebase config
///   platform: DevicePlatform.ios,
///   storePath: dbPath,
/// );
/// await poke.registerOnLaunch();   // anonymous install → dt_ persisted
/// await poke.identify(userId);      // bind to the developer's user id
/// ```
class PokeMe {
  PokeMe._({
    required IdentityClient identity,
    required PokeApiClient api,
    required MessageStore store,
    required PushService pushService,
  })  : _identity = identity,
        _api = api,
        _store = store,
        _pushService = pushService;

  final IdentityClient _identity;
  final PokeApiClient _api;
  final MessageStore _store;
  final PushService _pushService;
  final StreamController<PokeError> _errors =
      StreamController<PokeError>.broadcast();

  /// The identity orchestrator (register / identify / unidentify / refresh).
  IdentityClient get identity => _identity;

  /// The low-level HTTP client, for calls beyond the BYOA lifecycle.
  PokeApiClient get api => _api;

  /// The local store backing device-credential persistence (and message
  /// history, if the consumer uses it).
  MessageStore get store => _store;

  /// The most recent platform push token (APNs/FCM) the SDK obtained this
  /// session, or null if it hasn't fetched one. Diagnostic.
  String? get currentPushToken => _identity.currentPushToken;

  /// The server-issued device token (`dt_…`) used for `/devices/me/*` calls,
  /// or null if the device has never registered. Diagnostic.
  Future<String?> get deviceToken => _store.getDeviceToken();

  /// The server-assigned device id, or null if never registered. Diagnostic.
  Future<String?> get deviceId => _store.getDeviceId();

  /// Broadcast stream of parsed incoming pushes forwarded from the native
  /// layer. Listening begins at [init]; payloads delivered before a listener
  /// subscribes are not replayed.
  ///
  /// For a BYOA app, subject-origin alerts arrive as [AlertPayload]s carrying
  /// the addressed [AlertPayload.externalUserId].
  Stream<PushPayload> get pushes => _pushService.pushes;

  /// Broadcast stream of operation failures ([registerOnLaunch] / [identify] /
  /// [unidentify] / [refreshPushToken]).
  ///
  /// Each of those operations still **throws** (so awaiting callers handle
  /// errors inline), but it *also* emits a [PokeError] here — so failures from
  /// **fire-and-forget** calls (e.g. `unawaited(poke.registerOnLaunch(...))`)
  /// don't vanish. Wire this once to route errors to your telemetry:
  ///
  /// ```dart
  /// poke.errors.listen((e) => Sentry.captureException(e.error));
  /// ```
  ///
  /// Service errors are also logged via `dart:developer` under the `pokeme`
  /// name (toggle with `pokemeLoggingEnabled`).
  Stream<PokeError> get errors => _errors.stream;

  /// Builds and wires a [PokeMe] instance.
  ///
  /// [platform] is supplied by the host (the SDK does not infer it, to stay
  /// web-safe). [tokenService], [httpClient], and [databaseFactory] are
  /// injection seams for testing.
  ///
  /// **[apnsEnvironment] — read this.** It is the APNs environment of the token
  /// this binary will receive, forwarded to `identify` on Apple platforms. Do
  /// **NOT** gate it on Dart's `kReleaseMode` / `kDebugMode`: the environment is
  /// determined by the *aps-environment entitlement the binary was signed with*,
  /// not the compile mode. A `flutter run --release` to a development-signed
  /// device gets a **sandbox** token even though `kReleaseMode == true`. Passing
  /// `production` there makes every push fail with `BadDeviceToken`, after which
  /// the server cascade-revokes the device and pushes stop silently. Mirror your
  /// signing/entitlement, not your build mode. (Native auto-detection from the
  /// provisioning profile is planned.)
  static Future<PokeMe> init({
    required Uri baseUrl,
    required String appId,
    required String clientKey,
    required DevicePlatform platform,
    required String storePath,
    ApnsEnvironment? apnsEnvironment,
    PushTokenService? tokenService,
    http.Client? httpClient,
    DatabaseFactory? databaseFactory,
    Stream<Map<String, dynamic>>? pushSource,
  }) async {
    final store = await MessageStore.open(
      path: storePath,
      databaseFactory: databaseFactory,
    );
    final api = PokeApiClient(baseUrl: baseUrl, httpClient: httpClient);
    final identity = IdentityClient(
      tokenService: tokenService ?? PushTokenService(),
      apiClient: api,
      store: store,
      platform: platform,
      appId: appId,
      clientKey: clientKey,
      apnsEnvironment: apnsEnvironment,
    );
    final pushService = PushService(source: pushSource)..start();
    return PokeMe._(
      identity: identity,
      api: api,
      store: store,
      pushService: pushService,
    );
  }

  /// See [IdentityClient.registerOnLaunch]. Failures throw and are also emitted
  /// on [errors].
  Future<RegistrationStatus> registerOnLaunch({bool requestPermission = true}) =>
      _guard('registerOnLaunch',
          () => _identity.registerOnLaunch(requestPermission: requestPermission));

  /// See [IdentityClient.ensureRegistered] — recovers from a server-side
  /// cascade-revoke by re-registering if the server has lost this device's push
  /// token. Failures throw and are also emitted on [errors].
  Future<RegistrationStatus> ensureRegistered({bool requestPermission = true}) =>
      _guard('ensureRegistered',
          () => _identity.ensureRegistered(requestPermission: requestPermission));

  /// See [IdentityClient.identify]. Failures throw and are also emitted on
  /// [errors].
  Future<String> identify(String externalUserId,
          {ApnsEnvironment? apnsEnvironment}) =>
      _guard('identify',
          () => _identity.identify(externalUserId, apnsEnvironment: apnsEnvironment));

  /// See [IdentityClient.unidentify]. Failures throw and are also emitted on
  /// [errors].
  Future<void> unidentify() =>
      _guard('unidentify', () => _identity.unidentify());

  /// See [IdentityClient.refreshPushToken]. Failures throw and are also emitted
  /// on [errors].
  Future<void> refreshPushToken(PushTokenResult pushToken) =>
      _guard('refreshPushToken', () => _identity.refreshPushToken(pushToken));

  /// Runs [body], emitting any error on [errors] (so fire-and-forget callers
  /// still see it) before rethrowing for awaiting callers.
  Future<T> _guard<T>(String operation, Future<T> Function() body) async {
    try {
      return await body();
    } catch (error, stackTrace) {
      if (!_errors.isClosed) {
        _errors.add(PokeError(
          operation: operation,
          error: error,
          stackTrace: stackTrace,
        ));
      }
      rethrow;
    }
  }

  /// Closes the push and error streams, the HTTP client, and the local store.
  /// The instance must not be used afterwards.
  Future<void> close() async {
    await _pushService.dispose();
    await _errors.close();
    _api.close();
    await _store.close();
  }
}
