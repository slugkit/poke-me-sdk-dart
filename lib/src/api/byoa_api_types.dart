// BYOA (bring-your-own-app) DTOs for the poke-me backend HTTP API — the
// identity/unicast surface: register an anonymous install by client key,
// identify it to a subject by the developer's opaque external user id, and
// clear the binding on logout.
//
// These are core types (surfaced through `package:pokeme/pokeme.dart`) — the
// poke-me BYOA identity/unicast surface.
//
// Field naming follows the wire format (snake_case in JSON, camelCase in
// Dart).

import 'api_types.dart';

/// APNs delivery environment for an Apple device's push token.
///
/// Sent on [IdentifyRequest] so the backend dispatches via the matching APNs
/// host (sandbox for development builds, production for App Store / TestFlight).
enum ApnsEnvironment {
  sandbox,
  production;

  String get wireValue => name;
}

/// Body for `POST /api/v1/apps/{appId}/devices` — BYOA device registration.
///
/// **Planned contract** — the endpoint is not yet implemented backend-side
/// (see the poke-me BYOA model).
class RegisterDeviceRequest {
  const RegisterDeviceRequest({
    required this.platform,
    required this.pushToken,
    this.deviceId,
  });

  final DevicePlatform platform;
  final String pushToken;

  /// Locally-remembered device id from a previous registration, if any. Lets
  /// the backend reuse the existing `fanout.devices` row instead of minting a
  /// new one on reinstall/token-refresh churn.
  final String? deviceId;

  Map<String, dynamic> toJson() => {
        'platform': platform.wireValue,
        'push_token': pushToken,
        if (deviceId != null) 'device_id': deviceId,
      };
}

/// Response from `POST /api/v1/apps/{appId}/devices`.
class RegisterDeviceResponse {
  const RegisterDeviceResponse({
    required this.deviceId,
    required this.deviceToken,
  });

  final String deviceId;

  /// One-time bearer token (`dt_…`) for this device's `/devices/me/*` calls.
  /// Returned once at registration and stored locally; never re-fetchable.
  final String deviceToken;

  factory RegisterDeviceResponse.fromJson(Map<String, dynamic> json) {
    return RegisterDeviceResponse(
      deviceId: json['device_id'] as String,
      deviceToken: json['device_token'] as String,
    );
  }
}

/// Body for `POST /api/v1/devices/me/identify`.
class IdentifyRequest {
  const IdentifyRequest({
    required this.externalUserId,
    this.apnsEnvironment,
  });

  /// The developer's opaque end-user id (e.g. a RevenueCat app user id).
  /// poke-me stores it verbatim. The app is derived server-side from the
  /// authenticated device, so it is not sent here.
  final String externalUserId;

  /// APNs environment for this device's token. Optional; meaningful on Apple
  /// platforms only.
  final ApnsEnvironment? apnsEnvironment;

  Map<String, dynamic> toJson() => {
        'external_user_id': externalUserId,
        if (apnsEnvironment != null) 'apns_environment': apnsEnvironment!.wireValue,
      };
}

/// Response from `POST /api/v1/devices/me/identify`.
class IdentifyResponse {
  const IdentifyResponse({required this.subjectId});

  /// poke-me-internal subject id (uuidv7) the device is now bound to.
  final String subjectId;

  factory IdentifyResponse.fromJson(Map<String, dynamic> json) {
    return IdentifyResponse(subjectId: json['subject_id'] as String);
  }
}
