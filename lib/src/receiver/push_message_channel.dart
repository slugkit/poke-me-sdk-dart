import 'package:flutter/services.dart';

/// Bridges the native incoming-push [EventChannel] to a Dart stream of raw
/// payload maps.
///
/// The native plugin forwards every received push (Android
/// `FirebaseMessagingService`, Apple `didReceiveRemoteNotification`) over the
/// `io.pokeme.pokeme/push_messages` channel. This wrapper exposes those raw
/// maps verbatim; parsing (against the `design-docs/MESSAGES.md` envelope) and
/// dispatch live one layer up, in `PushService`.
class PushMessageChannel {
  PushMessageChannel({EventChannel? channel})
      : _channel = channel ?? const EventChannel(channelName);

  /// Native EventChannel name. Must match the plugin's Kotlin/Swift constant.
  static const channelName = 'io.pokeme.pokeme/push_messages';

  final EventChannel _channel;

  /// Broadcast stream of raw incoming push payloads, one event per delivered
  /// notification.
  Stream<Map<String, dynamic>> get messages =>
      _channel.receiveBroadcastStream().map(_coerce);

  static Map<String, dynamic> _coerce(dynamic event) {
    if (event is Map) return Map<String, dynamic>.from(event);
    throw FormatException(
      'Expected a Map push payload, got ${event.runtimeType}',
    );
  }
}
