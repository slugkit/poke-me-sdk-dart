import '../api/api_exception.dart';
import '../api/api_types.dart';
import '../api/poke_api_client.dart';
import '../models/channel.dart';
import '../push_token_service.dart';
import '../store/message_store.dart';

/// High-level orchestrator that turns a join key or routing key into a
/// fully-tracked local subscription.
///
/// Combines [PushTokenService] (platform push token), [PokeApiClient]
/// (HTTP), and [MessageStore] (local persistence) so callers don't have
/// to thread the device singletons (`device_id`, `device_token`) by hand.
///
/// Typical use:
/// ```dart
/// final result = await subscriber.subscribeByJoinKey('jk_abc123');
/// // result.channel is now in MessageStore.listChannels()
/// ```
class Subscriber {
  Subscriber({
    required PushTokenService tokenService,
    required PokeApiClient apiClient,
    required MessageStore messageStore,
    required DevicePlatform platform,
  })  : _tokenService = tokenService,
        _api = apiClient,
        _store = messageStore,
        _platform = platform;

  final PushTokenService _tokenService;
  final PokeApiClient _api;
  final MessageStore _store;
  final DevicePlatform _platform;

  /// Exchanges a join key for a subscription. The resulting channel is
  /// persisted locally and the device id/token are written to sync_state
  /// on first call.
  ///
  /// Throws [PokeApiException] on HTTP/transport errors and
  /// [PushTokenException] if the platform refuses to issue a push token.
  Future<Channel> subscribeByJoinKey(String joinKey) async {
    final pushToken = await _tokenService.getToken();
    final existingDeviceId = await _store.getDeviceId();

    final response = await _api.subscribeByJoinKey(
      SubscribeByKeyRequest(
        joinKey: joinKey,
        platform: _platform,
        pushToken: pushToken.token,
        deviceId: existingDeviceId,
      ),
    );

    return _persist(response);
  }

  /// Subscribes to a public channel by its full routing key (e.g.
  /// `acme/news`). The channel must be marked `is_public` server-side.
  Future<Channel> subscribeByRoutingKey(String routingKey) async {
    final pushToken = await _tokenService.getToken();
    final existingDeviceId = await _store.getDeviceId();

    final response = await _api.subscribeByRoutingKey(
      routingKey: routingKey,
      request: SubscribeByRoutingKeyRequest(
        platform: _platform,
        pushToken: pushToken.token,
        deviceId: existingDeviceId,
      ),
    );

    return _persist(response);
  }

  /// Removes a single channel subscription, both server-side and locally.
  ///
  /// Reads the bearer token and the channel's `subscription_id` from
  /// local storage; throws [StateError] if either is missing.
  Future<void> unsubscribe(String slug) async {
    final deviceToken = await _store.getDeviceToken();
    if (deviceToken == null) {
      throw StateError('No device token; the device has never subscribed.');
    }
    final channel = await _store.getChannel(slug);
    if (channel == null) {
      throw StateError('Unknown channel: $slug');
    }
    await _api.unsubscribe(
      deviceToken: deviceToken,
      subscriptionRef: channel.subscriptionId,
    );
    await _store.handleSubscriptionRevoked(slug);
  }

  /// Pushes a refreshed platform push token up to the backend.
  /// No-op if the device has never subscribed.
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

  Future<Channel> _persist(SubscribeResponse response) async {
    await _store.setDeviceCredentials(
      deviceId: response.deviceId,
      deviceToken: response.deviceToken,
    );
    final channel = Channel(
      slug: response.channel.slug,
      // The subscribe response does not yet include the channel name —
      // see slugkit/poke-me#46. Fall back to the slug so the UI has
      // something to display until the backend ships the field.
      name: response.channel.name ?? response.channel.slug,
      joinedAt: DateTime.now(),
      subscriptionId: response.subscriptionId,
    );
    await _store.joinChannel(channel);
    return channel;
  }
}
