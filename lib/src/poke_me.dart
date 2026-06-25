import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart' show DatabaseFactory;

import 'api/api_types.dart';
import 'api/byoa_api_types.dart';
import 'api/poke_api_client.dart';
import 'identity/identity_client.dart';
import 'push_token_service.dart';
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
  })  : _identity = identity,
        _api = api,
        _store = store;

  final IdentityClient _identity;
  final PokeApiClient _api;
  final MessageStore _store;

  /// The identity orchestrator (register / identify / unidentify / refresh).
  IdentityClient get identity => _identity;

  /// The low-level HTTP client, for calls beyond the BYOA lifecycle.
  PokeApiClient get api => _api;

  /// The local store backing device-credential persistence (and message
  /// history, if the consumer uses it).
  MessageStore get store => _store;

  /// Builds and wires a [PokeMe] instance.
  ///
  /// [platform] is supplied by the host (the SDK does not infer it, to stay
  /// web-safe); [apnsEnvironment] is forwarded to `identify` on Apple
  /// platforms. [tokenService], [httpClient], and [databaseFactory] are
  /// injection seams for testing.
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
    return PokeMe._(identity: identity, api: api, store: store);
  }

  /// See [IdentityClient.registerOnLaunch].
  Future<void> registerOnLaunch() => _identity.registerOnLaunch();

  /// See [IdentityClient.identify].
  Future<String> identify(String externalUserId) =>
      _identity.identify(externalUserId);

  /// See [IdentityClient.unidentify].
  Future<void> unidentify() => _identity.unidentify();

  /// See [IdentityClient.refreshPushToken].
  Future<void> refreshPushToken(PushTokenResult pushToken) =>
      _identity.refreshPushToken(pushToken);

  /// Closes the HTTP client and the local store. The instance must not be
  /// used afterwards.
  Future<void> close() async {
    _api.close();
    await _store.close();
  }
}
