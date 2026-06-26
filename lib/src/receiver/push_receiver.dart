import '../models/message.dart';
import '../store/message_store.dart';
import 'push_payload.dart';

/// Outcome of [PushReceiver.receive].
enum PushReceiveResult {
  /// Alert was new and stored successfully.
  alertStored,

  /// Alert was a duplicate (id already in store). FCM/APNs occasionally
  /// redeliver the same push.
  alertDuplicate,

  /// Alert was dropped because the channel is unknown locally or in a
  /// non-active state. The higher-level platform handler may attempt
  /// reconciliation via the backend history endpoint and retry.
  alertDropped,

  /// System event was applied. The reconciliation cursor
  /// (`sync_state.last_system_event_id`) has been advanced.
  systemEventApplied,

  /// System event name not recognised by this SDK version. Silently ignored
  /// per the forward-compatibility rules in MESSAGES.md. The cursor is **not**
  /// advanced — a future SDK upgrade may want to replay this event.
  systemEventUnknown,

  /// System event was structurally valid but missing required event-specific
  /// data (e.g. `channel_renamed` without `data.new_name`). The cursor is
  /// not advanced.
  systemEventInvalid,

  /// Payload could not be parsed (missing required envelope field, type
  /// mismatch, malformed JSON in extras, etc.). The cursor is not advanced.
  parseError,
}

/// High-level entry point for incoming push messages.
///
/// Sits between the platform push handler (FCM background isolate / APNs
/// delivery callback) and [MessageStore]. Parses the raw payload, validates
/// it, and dispatches to the appropriate store operation.
///
/// This layer is intentionally agnostic to:
/// - The platform delivery mechanism (FCM data message vs APNs custom keys
///   are both accepted by [parsePushPayload])
/// - The OS notification UI (the platform handler is responsible for
///   presenting the alert to the user; this layer only persists)
/// - HTTP/networking (slug history reconciliation lives in a higher layer
///   that owns the HTTP client)
class PushReceiver {
  PushReceiver({
    required this.store,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final MessageStore store;
  final DateTime Function() _clock;

  /// Process a raw push payload from FCM or APNs.
  ///
  /// Returns a [PushReceiveResult] describing what happened. Never throws —
  /// all parse errors are translated to [PushReceiveResult.parseError].
  Future<PushReceiveResult> receive(Map<String, dynamic> rawPayload) async {
    final PushPayload payload;
    try {
      payload = parsePushPayload(rawPayload);
    } on FormatException {
      return PushReceiveResult.parseError;
    }

    return switch (payload) {
      AlertPayload() => _handleAlert(payload),
      SystemPayload() => _handleSystem(payload),
    };
  }

  Future<PushReceiveResult> _handleAlert(AlertPayload alert) async {
    final channelSlug = alert.channelSlug;
    if (channelSlug == null) {
      // Subject-origin (BYOA) alerts have no channel and are not part of the
      // channel history this receiver maintains. The higher layer surfaces
      // them via the pushes stream instead.
      return PushReceiveResult.alertDropped;
    }
    final message = Message(
      id: alert.id,
      channelSlug: channelSlug,
      sentAt: alert.sentAt,
      receivedAt: _clock(),
      priority: alert.priority,
      title: alert.title,
      body: alert.body,
      url: alert.url,
      extras: alert.extras,
      v: alert.v,
    );
    final result = await store.receiveMessage(message);
    return switch (result) {
      MessageReceiveResult.inserted => PushReceiveResult.alertStored,
      MessageReceiveResult.duplicate => PushReceiveResult.alertDuplicate,
      MessageReceiveResult.dropped => PushReceiveResult.alertDropped,
    };
  }

  Future<PushReceiveResult> _handleSystem(SystemPayload event) async {
    final channelSlug = event.channelSlug;
    if (channelSlug == null) {
      // System events are channel-origin reconciliation; one without a channel
      // is malformed.
      return PushReceiveResult.systemEventInvalid;
    }
    final result = await _dispatchSystem(event, channelSlug);
    if (result == PushReceiveResult.systemEventApplied) {
      await store.recordLastSystemEventId(event.id);
    }
    return result;
  }

  Future<PushReceiveResult> _dispatchSystem(
    SystemPayload event,
    String channelSlug,
  ) async {
    switch (event.event) {
      case 'channel_renamed':
        final newName = event.data?['new_name'];
        if (newName is! String || newName.isEmpty) {
          return PushReceiveResult.systemEventInvalid;
        }
        await store.handleChannelRenamed(channelSlug, newName);
        return PushReceiveResult.systemEventApplied;

      case 'channel_slug_changed':
        final newSlug = event.data?['new_slug'];
        if (newSlug is! String || newSlug.isEmpty) {
          return PushReceiveResult.systemEventInvalid;
        }
        await store.handleChannelSlugChanged(channelSlug, newSlug);
        return PushReceiveResult.systemEventApplied;

      case 'channel_deleted':
        await store.handleChannelDeleted(channelSlug, at: _clock());
        return PushReceiveResult.systemEventApplied;

      case 'subscription_revoked':
        await store.handleSubscriptionRevoked(channelSlug, at: _clock());
        return PushReceiveResult.systemEventApplied;

      default:
        return PushReceiveResult.systemEventUnknown;
    }
  }
}
