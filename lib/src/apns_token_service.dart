import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'push_token_service.dart';

const _channel = MethodChannel('io.pokeme.pokeme/push_token');
const _refreshChannel = EventChannel('io.pokeme.pokeme/push_token_refresh');

/// Push token retrieval via native MethodChannel.
///
/// Delegates to platform-specific native code:
/// - iOS/macOS: APNs token (Swift)
/// - Android: FCM token (Kotlin)
class ApnsTokenService implements PushTokenService {
  PushTokenType get _tokenType =>
      Platform.isAndroid ? PushTokenType.fcm : PushTokenType.apns;

  @override
  Future<PushTokenResult> getToken({bool requestPermission = true}) async {
    try {
      final token = await _channel.invokeMethod<String>(
        'getToken',
        {'requestPermission': requestPermission},
      );
      if (token == null || token.isEmpty) {
        throw PushTokenException(
          'No push token returned. '
          'Push notifications may be unavailable on this device.',
        );
      }
      return PushTokenResult(type: _tokenType, token: token);
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
  Future<void> openSettings() async {
    try {
      await _channel.invokeMethod('openSettings');
    } on PlatformException {
      // Not implemented on this platform — ignore.
    }
  }
}
