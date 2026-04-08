// DTOs for the poke-me backend HTTP API.
//
// Field naming follows the wire format (snake_case in JSON, camelCase
// in Dart) and the API contract documented in
// `design-docs/backend/API.md`.

/// Platform identifier accepted by the subscribe endpoints.
///
/// Maps to `ios | android | macos | web` on the wire.
enum DevicePlatform {
  ios,
  android,
  macos,
  web;

  String get wireValue => name;
}

/// Body for `POST /api/v1/subscribe/by-key`.
class SubscribeByKeyRequest {
  const SubscribeByKeyRequest({
    required this.joinKey,
    required this.platform,
    required this.pushToken,
    this.deviceId,
  });

  final String joinKey;
  final DevicePlatform platform;
  final String pushToken;
  final String? deviceId;

  Map<String, dynamic> toJson() => {
        'join_key': joinKey,
        'platform': platform.wireValue,
        'push_token': pushToken,
        if (deviceId != null) 'device_id': deviceId,
      };
}

/// Body for `POST /api/v1/subscribe/{full_routing_key}`.
class SubscribeByRoutingKeyRequest {
  const SubscribeByRoutingKeyRequest({
    required this.platform,
    required this.pushToken,
    this.deviceId,
  });

  final DevicePlatform platform;
  final String pushToken;
  final String? deviceId;

  Map<String, dynamic> toJson() => {
        'platform': platform.wireValue,
        'push_token': pushToken,
        if (deviceId != null) 'device_id': deviceId,
      };
}

/// Channel detail returned inside a [SubscribeResponse].
class ApiChannel {
  const ApiChannel({
    required this.slug,
    this.id,
    this.name,
    this.routingKey,
  });

  /// Channel slug as the device will see it on incoming alerts.
  final String slug;

  /// Server-side channel UUID, when the response includes it.
  final String? id;

  /// Display name. Currently absent from the subscribe response — see
  /// slugkit/poke-me#46. Callers should fall back to [slug] when null.
  final String? name;

  /// Full routing key (e.g. `acme/news`). May equal [slug] for
  /// non-namespaced channels.
  final String? routingKey;

  factory ApiChannel.fromJson(Map<String, dynamic> json) {
    return ApiChannel(
      slug: json['slug'] as String,
      id: json['id'] as String?,
      name: json['name'] as String?,
      routingKey: json['routing_key'] as String?,
    );
  }
}

/// Response from both subscribe endpoints.
class SubscribeResponse {
  const SubscribeResponse({
    required this.deviceId,
    required this.subscriptionId,
    required this.deviceToken,
    required this.channel,
  });

  final String deviceId;
  final String subscriptionId;
  final String deviceToken;
  final ApiChannel channel;

  factory SubscribeResponse.fromJson(Map<String, dynamic> json) {
    return SubscribeResponse(
      deviceId: json['device_id'] as String,
      subscriptionId: json['subscription_id'] as String,
      deviceToken: json['device_token'] as String,
      channel: ApiChannel.fromJson(json['channel'] as Map<String, dynamic>),
    );
  }
}

/// Body for `PUT /api/v1/devices/me/push-token`.
class UpdatePushTokenRequest {
  const UpdatePushTokenRequest({
    required this.platform,
    required this.pushToken,
  });

  final DevicePlatform platform;
  final String pushToken;

  Map<String, dynamic> toJson() => {
        'platform': platform.wireValue,
        'push_token': pushToken,
      };
}

/// Subscription element of the response from `GET /api/v1/devices/me`.
///
/// The current backend returns this slim shape inside the device row.
/// The richer fields (channel name, joined_at) are tracked under
/// slugkit/poke-me#46 and slugkit/poke-me#48.
class DeviceSubscription {
  const DeviceSubscription({
    required this.id,
    required this.channelId,
    required this.channelSlug,
    required this.via,
  });

  /// Per-channel subscription id, the same value the subscribe
  /// response returned and the path parameter for
  /// `DELETE /api/v1/devices/me/subscriptions/{id}`.
  final String id;

  /// Server-side channel UUID.
  final String channelId;

  /// Channel slug as it appears on incoming alerts.
  final String channelSlug;

  /// How the device joined: `join_key`, `routing_key`, etc.
  final String via;

  factory DeviceSubscription.fromJson(Map<String, dynamic> json) {
    return DeviceSubscription(
      id: json['id'] as String,
      channelId: json['channel_id'] as String,
      channelSlug: json['channel_slug'] as String,
      via: json['via'] as String,
    );
  }
}

/// Response from `GET /api/v1/devices/me`.
class Device {
  const Device({
    required this.id,
    required this.platform,
    required this.pushToken,
    required this.subscriptions,
  });

  final String id;
  final String platform;
  final String pushToken;
  final List<DeviceSubscription> subscriptions;

  factory Device.fromJson(Map<String, dynamic> json) {
    final subs = (json['subscriptions'] as List?) ?? const [];
    return Device(
      id: json['id'] as String,
      platform: json['platform'] as String,
      pushToken: json['push_token'] as String,
      subscriptions: subs
          .map((e) => DeviceSubscription.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Element of the response from `GET /api/v1/devices/me/channels`.
///
/// **Note:** as of slugkit/poke-me#48, this endpoint is not yet
/// implemented backend-side. Use [Device.subscriptions] from
/// `GET /api/v1/devices/me` instead until the dedicated endpoint
/// ships with the richer fields (channel name, joined_at).
class DeviceChannel {
  const DeviceChannel({
    required this.subscriptionId,
    required this.slug,
    required this.name,
    required this.joinedAt,
  });

  final String subscriptionId;
  final String slug;
  final String name;
  final DateTime joinedAt;

  factory DeviceChannel.fromJson(Map<String, dynamic> json) {
    return DeviceChannel(
      subscriptionId: json['subscription_id'] as String,
      slug: json['slug'] as String,
      name: json['name'] as String,
      joinedAt: DateTime.parse(json['joined_at'] as String),
    );
  }
}

/// Element of the response from `GET /api/v1/devices/me/events?since=`.
///
/// Mirrors the system event types from `design-docs/MESSAGES.md`.
class DeviceSystemEvent {
  const DeviceSystemEvent({
    required this.id,
    required this.sentAt,
    required this.channelSlug,
    required this.event,
    this.data,
  });

  final String id;
  final DateTime sentAt;
  final String channelSlug;
  final String event;
  final Map<String, dynamic>? data;

  factory DeviceSystemEvent.fromJson(Map<String, dynamic> json) {
    return DeviceSystemEvent(
      id: json['id'] as String,
      sentAt: DateTime.fromMillisecondsSinceEpoch(json['sent_at'] as int),
      channelSlug: json['channel_slug'] as String,
      event: json['event'] as String,
      data: json['data'] as Map<String, dynamic>?,
    );
  }
}

/// Element of the response from
/// `GET /api/v1/devices/me/channels/{slug}/history`.
class ChannelHistoryEntry {
  const ChannelHistoryEntry({
    required this.slug,
    required this.name,
    required this.changedAt,
  });

  final String slug;
  final String name;
  final DateTime changedAt;

  factory ChannelHistoryEntry.fromJson(Map<String, dynamic> json) {
    return ChannelHistoryEntry(
      slug: json['slug'] as String,
      name: json['name'] as String,
      changedAt: DateTime.parse(json['changed_at'] as String),
    );
  }
}
