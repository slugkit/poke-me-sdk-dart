import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'api/byoa_api_types.dart';
import 'push_token_service.dart';

const _channel = MethodChannel('io.pokeme.pokeme/push_token');
const _refreshChannel = EventChannel('io.pokeme.pokeme/push_token_refresh');

/// Push token retrieval via native MethodChannel.
///
/// Delegates to platform-specific native code:
/// - iOS/macOS: APNs token (Swift)
/// - Android: FCM token (Kotlin)
class ApnsTokenService implements PushTokenService {
  ApnsTokenService({this.timeout = const Duration(seconds: 30)});

  /// Upper bound on how long [getToken] waits for the native side. Platform
  /// push registration is normally sub-second; the timeout exists so a
  /// misconfigured build surfaces a clear error instead of hanging forever
  /// (e.g. if the APNs registration callback never arrives — see SETUP.md).
  final Duration timeout;

  PushTokenType get _tokenType =>
      Platform.isAndroid ? PushTokenType.fcm : PushTokenType.apns;

  @override
  Future<PushTokenResult> getToken({bool requestPermission = true}) async {
    try {
      final token = await _channel.invokeMethod<String>(
        'getToken',
        {'requestPermission': requestPermission},
      ).timeout(timeout);
      if (token == null || token.isEmpty) {
        throw PushTokenException(
          'No push token returned. '
          'Push notifications may be unavailable on this device.',
        );
      }
      return PushTokenResult(type: _tokenType, token: token);
    } on TimeoutException {
      throw PushTokenException(
        'Timed out after ${timeout.inSeconds}s waiting for the push token. '
        'On macOS, ensure the app can receive the APNs registration callback '
        '(see SETUP.md).',
        code: 'TIMEOUT',
      );
    } on PlatformException catch (e) {
      throw PushTokenException(
        e.message ?? 'Failed to get push token',
        code: e.code,
      );
    }
  }

  @override
  Stream<PushTokenResult> get onTokenRefresh {
    return _refreshChannel.receiveBroadcastStream().map(
      (event) => PushTokenResult(
        type: _tokenType,
        token: event as String,
      ),
    );
  }

  @override
  Future<void> openSettings() => _maybeCall<void>('openSettings');

  @override
  Future<void> configureAndroidNotifications({required bool autoDisplay}) =>
      _maybeCall<void>(
        'configureAndroidNotifications',
        {'autoDisplay': autoDisplay},
      );

  @override
  Future<ApnsEnvironment?> detectApnsEnvironment() async {
    final value = await _maybeCall<String>('getApnsEnvironment');
    switch (value) {
      case 'sandbox':
        return ApnsEnvironment.sandbox;
      case 'production':
        return ApnsEnvironment.production;
      default:
        return null;
    }
  }

  /// Invokes a platform method that may not exist on the current target (e.g.
  /// Android-only notification config, Apple-only env detection). Returns null
  /// and swallows both [PlatformException] **and** [MissingPluginException] —
  /// the latter is *not* a subclass of the former, so it must be caught
  /// explicitly. This keeps best-effort calls from leaking out of `PokeMe.init`
  /// on platforms where the native side doesn't implement the method.
  Future<T?> _maybeCall<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
