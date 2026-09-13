import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart' show DatabaseFactory;

import 'api/api_types.dart';
import 'api/byoa_api_types.dart';
import 'api/poke_api_client.dart';
import 'api/receipt_api_types.dart';
import 'identity/identity_client.dart';
import 'poke_error.dart';
import 'push_token_service.dart';
import 'receipts/receipt_reporter.dart';
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
    required ReceiptReporter? receipts,
  })  : _identity = identity,
        _api = api,
        _store = store,
        _pushService = pushService,
        _receipts = receipts;

  final IdentityClient _identity;
  final PokeApiClient _api;
  final MessageStore _store;
  final PushService _pushService;
  final ReceiptReporter? _receipts;
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

  /// The delivery-receipt reporter, or null when receipts are off
  /// (`PokeMe.init(reportReceipts: false)`). Diagnostic — [reportShown],
  /// [reportOpened] and [flushReceipts] are the surface to use.
  ReceiptReporter? get receipts => _receipts;

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
  /// **[apnsEnvironment]** — the APNs environment of the token this binary
  /// receives, forwarded to `identify` on Apple platforms. When omitted, the
  /// SDK **auto-detects** it from the embedded provisioning profile (the
  /// signing entitlement — the correct source of truth), so most apps should
  /// leave it null. Pass it explicitly only to override.
  ///
  /// Do **NOT** gate it on Dart's `kReleaseMode` / `kDebugMode`: a
  /// `flutter run --release` to a development-signed device gets a **sandbox**
  /// token even though `kReleaseMode == true`. Passing `production` there makes
  /// every push fail with `BadDeviceToken`, after which the server
  /// cascade-revokes the device and pushes stop silently.
  ///
  /// **[androidAutoDisplay]** — on Android the SDK posts a system notification
  /// for incoming pushes itself (the backend sends data-only FCM, which Android
  /// never auto-displays — unlike APNs alerts on iOS/macOS). Set to false if
  /// your app renders its own notifications from [pushes]. No effect off Android.
  ///
  /// **[reportReceipts]** — tell poke-me what became of each notification
  /// (delivered / shown / opened). Nothing else can: APNs and Web Push have no
  /// receipts, and FCM's live in your own Firebase project. Reports are
  /// batched, debounced and dropped after one failed retry, so the cost is one
  /// small request per app-resume rather than one per notification. Set to
  /// false to send none. Note that receipts are a paid poke-me feature — if
  /// your plan does not include them the backend says so and the SDK stops
  /// reporting on its own, so leaving this on costs nothing either way.
  static Future<PokeMe> init({
    required Uri baseUrl,
    required String appId,
    required String clientKey,
    required DevicePlatform platform,
    required String storePath,
    ApnsEnvironment? apnsEnvironment,
    bool androidAutoDisplay = true,
    bool reportReceipts = true,
    PushTokenService? tokenService,
    http.Client? httpClient,
    DatabaseFactory? databaseFactory,
    Stream<Map<String, dynamic>>? pushSource,
  }) async {
    final store = await MessageStore.open(
      path: storePath,
      databaseFactory: databaseFactory,
    );
    final resolvedTokenService = tokenService ?? PushTokenService();
    // Prefer the explicit value; otherwise auto-detect from the signing
    // entitlement (the correct source of truth — see the docstring above).
    final resolvedApnsEnvironment =
        apnsEnvironment ?? await resolvedTokenService.detectApnsEnvironment();
    // Android renders system notifications itself (the backend sends data-only
    // FCM, which the OS never auto-displays). No-op on other platforms.
    await resolvedTokenService.configureAndroidNotifications(
      autoDisplay: androidAutoDisplay,
    );
    final api = PokeApiClient(baseUrl: baseUrl, httpClient: httpClient);
    final identity = IdentityClient(
      tokenService: resolvedTokenService,
      apiClient: api,
      store: store,
      platform: platform,
      appId: appId,
      clientKey: clientKey,
      apnsEnvironment: resolvedApnsEnvironment,
    );
    final reporter = reportReceipts
        ? ReceiptReporter(api: api, deviceToken: store.getDeviceToken)
        : null;
    final pushService = PushService(
      source: pushSource,
      onObserved: reporter?.report,
    )..start();
    return PokeMe._(
      identity: identity,
      api: api,
      store: store,
      pushService: pushService,
      receipts: reporter,
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

  /// Reports that the OS displayed a notification, by its [PushPayload.id].
  ///
  /// Call it only if your app renders notifications itself (Android with
  /// `androidAutoDisplay: false`, or a custom in-app presentation). When the
  /// SDK does the rendering it reports this for you.
  ///
  /// Buffered and sent with the next flush; never throws.
  void reportShown(String notificationId) =>
      _receipts?.report(notificationId, ReceiptState.shown);

  /// Reports that the user acted on a notification, by its [PushPayload.id].
  ///
  /// The SDK reports this itself for notifications it rendered. Call it from
  /// your own tap handler when your app owns the presentation, or for an
  /// in-app surface the OS knows nothing about.
  ///
  /// Buffered and sent with the next flush; never throws.
  void reportOpened(String notificationId) =>
      _receipts?.report(notificationId, ReceiptState.opened);

  /// Sends buffered receipts now rather than waiting out the debounce.
  ///
  /// Worth calling when the app goes to the background — that is the moment the
  /// buffer is most likely to be lost. Never throws.
  Future<void> flushReceipts() async {
    try {
      await _receipts?.flush();
    } catch (_) {
      // Telemetry must not be able to fail a lifecycle callback.
    }
  }

  /// Closes the push and error streams, the HTTP client, and the local store.
  /// The instance must not be used afterwards.
  Future<void> close() async {
    await _receipts?.close();
    await _pushService.dispose();
    await _errors.close();
    _api.close();
    await _store.close();
  }
}
