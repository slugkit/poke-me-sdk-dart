import 'dart:convert';

import '../models/message.dart';

/// Parsed push payload from FCM or APNs.
///
/// Sealed type hierarchy: a payload is either an [AlertPayload] (user-facing
/// notification) or a [SystemPayload] (silently-processed channel state event).
/// See `design-docs/MESSAGES.md` for the wire schema.
sealed class PushPayload {
  const PushPayload({
    required this.v,
    required this.id,
    required this.sentAt,
    required this.channelSlug,
  });

  /// Feature generation marker. The receiver can ignore unknown future fields
  /// gracefully and still process the basic envelope.
  final int v;

  /// Server-assigned UUIDv7. Sortable by send time. Acts as the dedup key.
  final String id;

  /// When the message was sent (server-assigned).
  final DateTime sentAt;

  /// Routing key. Free-form opaque string from the receiver's POV.
  final String channelSlug;
}

/// User-facing alert. Stored in the local message history and surfaced to
/// the user via an OS notification.
final class AlertPayload extends PushPayload {
  const AlertPayload({
    required super.v,
    required super.id,
    required super.sentAt,
    required super.channelSlug,
    required this.channelName,
    required this.title,
    required this.body,
    this.priority = MessagePriority.normal,
    this.url,
    this.extras,
  });

  /// Human-readable channel label, denormalised so the receiver can display
  /// without a server lookup.
  final String channelName;

  /// Notification priority.
  final MessagePriority priority;

  final String title;
  final String body;

  /// Optional tap-action target.
  final String? url;

  /// Publisher-defined opaque JSON.
  final Map<String, dynamic>? extras;
}

/// System event. Silently processed by the SDK to keep the local state
/// in sync with the server. Never displayed to the user.
final class SystemPayload extends PushPayload {
  const SystemPayload({
    required super.v,
    required super.id,
    required super.sentAt,
    required super.channelSlug,
    required this.event,
    this.data,
  });

  /// Event type. Receivers ignore unknown events.
  final String event;

  /// Event-specific payload.
  final Map<String, dynamic>? data;
}

/// Parses a raw push payload from either an FCM data message or APNs custom
/// keys delivery.
///
/// FCM coerces all values to strings; APNs preserves native JSON types
/// (alongside the `aps` dictionary). This parser is tolerant of both: it
/// accepts strings, integers, and native maps where appropriate.
///
/// Throws [FormatException] with a descriptive message on any structural
/// problem (missing required field, type mismatch, invalid enum value).
PushPayload parsePushPayload(Map<String, dynamic> raw) {
  final kind = _requireString(raw, 'kind');
  final v = _requireInt(raw, 'v');
  final id = _requireString(raw, 'id');
  final sentAtMs = _requireInt(raw, 'sent_at');
  final sentAt = DateTime.fromMillisecondsSinceEpoch(sentAtMs);
  final channelSlug = _requireString(raw, 'channel_slug');

  switch (kind) {
    case 'alert':
      final channelName = _requireString(raw, 'channel_name');
      final title = _requireString(raw, 'title');
      final body = _requireString(raw, 'body');
      final priority = _parsePriority(raw['priority']);
      final url = _optionalString(raw, 'url');
      final extras = _parseObject(raw['extras']);
      return AlertPayload(
        v: v,
        id: id,
        sentAt: sentAt,
        channelSlug: channelSlug,
        channelName: channelName,
        title: title,
        body: body,
        priority: priority,
        url: url,
        extras: extras,
      );

    case 'system':
      final event = _requireString(raw, 'event');
      final data = _parseObject(raw['data']);
      return SystemPayload(
        v: v,
        id: id,
        sentAt: sentAt,
        channelSlug: channelSlug,
        event: event,
        data: data,
      );

    default:
      throw FormatException(
        "Invalid 'kind' field: expected 'alert' or 'system', got '$kind'",
      );
  }
}

// -----------------------------------------------------------------------------
// Internal parsing helpers
// -----------------------------------------------------------------------------

String _requireString(Map<String, dynamic> raw, String key) {
  final value = raw[key];
  if (value == null) {
    throw FormatException("Missing required field '$key'");
  }
  if (value is! String) {
    throw FormatException(
      "Field '$key' must be a string, got ${value.runtimeType}",
    );
  }
  if (value.isEmpty) {
    throw FormatException("Field '$key' must not be empty");
  }
  return value;
}

String? _optionalString(Map<String, dynamic> raw, String key) {
  final value = raw[key];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException(
      "Field '$key' must be a string, got ${value.runtimeType}",
    );
  }
  return value.isEmpty ? null : value;
}

int _requireInt(Map<String, dynamic> raw, String key) {
  final value = raw[key];
  if (value == null) {
    throw FormatException("Missing required field '$key'");
  }
  if (value is int) return value;
  if (value is String) {
    final parsed = int.tryParse(value);
    if (parsed == null) {
      throw FormatException(
        "Field '$key' must be an integer, got '$value'",
      );
    }
    return parsed;
  }
  throw FormatException(
    "Field '$key' must be an integer, got ${value.runtimeType}",
  );
}

MessagePriority _parsePriority(dynamic value) {
  if (value == null) return MessagePriority.normal;
  if (value is! String) {
    throw FormatException(
      "Field 'priority' must be a string, got ${value.runtimeType}",
    );
  }
  try {
    return MessagePriority.fromString(value);
  } on ArgumentError catch (e) {
    throw FormatException(e.message?.toString() ?? "Invalid 'priority' value");
  }
}

Map<String, dynamic>? _parseObject(dynamic value) {
  if (value == null) return null;
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  if (value is String) {
    if (value.isEmpty) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      throw FormatException(
        "Expected object, decoded JSON was ${decoded.runtimeType}",
      );
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException("Invalid JSON object: $e");
    }
  }
  throw FormatException(
    "Expected object or JSON string, got ${value.runtimeType}",
  );
}
