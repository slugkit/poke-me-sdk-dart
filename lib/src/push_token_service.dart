import 'api/byoa_api_types.dart';
import 'apns_token_service.dart';

/// The type of push token obtained from the platform.
enum PushTokenType {
  /// Apple Push Notification service token (iOS, macOS).
  apns,

  /// Firebase Cloud Messaging token (Android).
  fcm,
}

/// Result of a push token retrieval attempt.
class PushTokenResult {
  PushTokenResult({required this.type, required this.token});

  final PushTokenType type;
  final String token;

  @override
  String toString() => '${type.name.toUpperCase()} token: $token';
}

/// Platform-agnostic interface for push token retrieval.
///
/// Use the factory constructor to get the correct implementation:
///
/// ```dart
/// final service = PushTokenService();
/// final result = await service.getToken();
/// print('${result.type}: ${result.token}');
/// ```
abstract class PushTokenService {
  /// Creates the appropriate platform implementation.
  ///
  /// All platforms use the same [ApnsTokenService] which communicates
  /// via MethodChannel to platform-specific native code:
  /// - iOS/macOS: APNs token retrieval (Swift)
  /// - Android: FCM token retrieval (Kotlin)
  factory PushTokenService() => ApnsTokenService();

  /// Retrieves the platform push token.
  ///
  /// When [requestPermission] is true (default), notification permission is
  /// requested on Apple platforms — the system prompt is shown if the user has
  /// not been asked yet. When false, **no prompt is shown**: a token is
  /// returned only if permission was already granted, otherwise a
  /// [PushTokenException] (with [PushTokenException.isPermissionDenied] true)
  /// is thrown. Pass false to defer the prompt to a contextual moment, per the
  /// Apple Human Interface Guidelines.
  ///
  /// On Android the flag has no effect — fetching the FCM token never prompts.
  ///
  /// Throws [PushTokenException] if permission is denied / not yet requested,
  /// or the token cannot be obtained.
  Future<PushTokenResult> getToken({bool requestPermission = true});

  /// Stream of token updates. Emits a new result whenever the platform
  /// rotates the push token.
  Stream<PushTokenResult> get onTokenRefresh;

  /// Opens the OS notification settings for this app.
  Future<void> openSettings();

  /// Auto-detects the APNs environment from the embedded provisioning profile
  /// on Apple platforms (`sandbox` / `production`). Returns null when it can't
  /// be determined (Android, web, or an App Store build with no embedded
  /// profile) — the caller should fall back to a configured value.
  ///
  /// This reflects the **signing entitlement**, which is the correct source of
  /// truth — unlike Dart's `kReleaseMode`.
  Future<ApnsEnvironment?> detectApnsEnvironment();
}

/// Thrown when push token retrieval fails.
class PushTokenException implements Exception {
  PushTokenException(this.message, {this.code});

  final String message;
  final String? code;

  bool get isPermissionDenied =>
      code == 'PERMISSION_DENIED' || code == 'PERMISSION_NOT_DETERMINED';

  @override
  String toString() => 'PushTokenException: $message';
}
