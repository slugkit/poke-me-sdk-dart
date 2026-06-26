// Core transport DTOs for the poke-me backend HTTP API — the device/identity
// types shared by every consumer. Channel-layer (v1 subscribe) DTOs live in
// `channel_api_types.dart` and surface only through
// `package:pokeme/channels.dart`.
//
// Field naming follows the wire format (snake_case in JSON, camelCase
// in Dart) and the poke-me HTTP API contract.

/// Platform identifier accepted by the device endpoints.
///
/// Maps to `ios | android | macos | web` on the wire.
enum DevicePlatform {
  ios,
  android,
  macos,
  web;

  String get wireValue => name;
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
