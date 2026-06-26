/// Priority levels carried in alert messages.
///
/// See `design-docs/MESSAGES.md` for the per-platform mapping.
enum MessagePriority {
  /// FYIs, batched updates.
  low,

  /// Standard alerts. Default if not specified.
  normal,

  /// Pages, urgent alerts.
  high,

  /// Bypasses Do Not Disturb. Defined in v1 schema but **not yet implemented**;
  /// gated behind a future paid add-on requiring Apple's Critical Alerts entitlement.
  critical;

  /// Parses the textual form stored in SQLite.
  static MessagePriority fromString(String value) {
    return MessagePriority.values.firstWhere(
      (p) => p.name == value,
      orElse: () => throw ArgumentError('Unknown MessagePriority: $value'),
    );
  }
}

/// A user-facing alert message received from the poke-me service.
///
/// Mirrors a row in the `messages` table. System events (`kind: system` in
/// the wire format) are not represented here — they are processed by the SDK
/// and never stored.
class Message {
  Message({
    required this.id,
    required this.channelSlug,
    required this.sentAt,
    required this.receivedAt,
    required this.title,
    required this.body,
    this.priority = MessagePriority.normal,
    this.url,
    this.extras,
    this.readAt,
    this.v = 1,
  });

  /// Server-assigned UUIDv7. Sortable by send time. Acts as the dedup key.
  final String id;

  /// Slug of the channel this message belongs to.
  final String channelSlug;

  /// When the message was sent (server-assigned).
  final DateTime sentAt;

  /// When the device received the push.
  final DateTime receivedAt;

  /// Notification priority.
  final MessagePriority priority;

  final String title;
  final String body;

  /// Optional tap-action target.
  final String? url;

  /// Publisher-defined opaque JSON. Stored verbatim so future SDK versions
  /// can interpret newly-introduced fields without losing data.
  final Map<String, dynamic>? extras;

  /// When the user marked the message as read. Null = unread.
  final DateTime? readAt;

  /// Feature generation marker from the message envelope.
  final int v;

  bool get isRead => readAt != null;

  /// Returns a copy with the given fields replaced.
  Message copyWith({
    String? id,
    String? channelSlug,
    DateTime? sentAt,
    DateTime? receivedAt,
    MessagePriority? priority,
    String? title,
    String? body,
    String? url,
    Map<String, dynamic>? extras,
    DateTime? readAt,
    int? v,
    bool clearUrl = false,
    bool clearExtras = false,
    bool clearReadAt = false,
  }) {
    return Message(
      id: id ?? this.id,
      channelSlug: channelSlug ?? this.channelSlug,
      sentAt: sentAt ?? this.sentAt,
      receivedAt: receivedAt ?? this.receivedAt,
      priority: priority ?? this.priority,
      title: title ?? this.title,
      body: body ?? this.body,
      url: clearUrl ? null : (url ?? this.url),
      extras: clearExtras ? null : (extras ?? this.extras),
      readAt: clearReadAt ? null : (readAt ?? this.readAt),
      v: v ?? this.v,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Message &&
          id == other.id &&
          channelSlug == other.channelSlug &&
          sentAt == other.sentAt &&
          receivedAt == other.receivedAt &&
          priority == other.priority &&
          title == other.title &&
          body == other.body &&
          url == other.url &&
          readAt == other.readAt &&
          v == other.v;

  @override
  int get hashCode => Object.hash(
        id,
        channelSlug,
        sentAt,
        receivedAt,
        priority,
        title,
        body,
        url,
        readAt,
        v,
      );
}
