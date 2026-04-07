/// Lifecycle state of a locally-tracked channel subscription.
enum ChannelState {
  /// Normal operation. Messages are accepted and displayed.
  active,

  /// Server told us via `subscription_revoked`. Messages already wiped;
  /// the row is kept until the user acknowledges the notice.
  revoked,

  /// Server told us via `channel_deleted`. Messages already wiped;
  /// the row is kept until the user acknowledges the notice.
  deleted;

  /// Parses the textual form stored in SQLite.
  static ChannelState fromString(String value) {
    return ChannelState.values.firstWhere(
      (s) => s.name == value,
      orElse: () => throw ArgumentError('Unknown ChannelState: $value'),
    );
  }
}

/// A channel the device is or was subscribed to.
///
/// Mirrors a row in the `channels` table.
class Channel {
  Channel({
    required this.slug,
    required this.name,
    required this.joinedAt,
    required this.deviceToken,
    this.state = ChannelState.active,
    this.stateChangedAt,
    this.acknowledgedAt,
    this.retentionDays,
  });

  /// Current slug. Updated when a `channel_slug_changed` system event arrives.
  final String slug;

  /// Human-readable channel name. Updated when a `channel_renamed` system event arrives.
  final String name;

  /// When the device first joined this channel.
  final DateTime joinedAt;

  /// Per-channel auth token issued by the backend (NOT the platform push token).
  /// Used for authenticated read-only API calls (reconciliation, history).
  final String deviceToken;

  /// Lifecycle state.
  final ChannelState state;

  /// When [state] last moved away from [ChannelState.active]. Null while active.
  final DateTime? stateChangedAt;

  /// When the user acknowledged the deletion/revocation notice. Null until shown.
  /// Used by the tombstone sweep to schedule hard-deletion one day later.
  final DateTime? acknowledgedAt;

  /// Per-channel retention override in days.
  ///
  /// - `null` — fall back to the global default in `sync_state`.
  /// - `0` — unlimited (never prune).
  /// - any positive integer — prune messages older than N days.
  final int? retentionDays;

  /// Returns a copy with the given fields replaced.
  Channel copyWith({
    String? slug,
    String? name,
    DateTime? joinedAt,
    String? deviceToken,
    ChannelState? state,
    DateTime? stateChangedAt,
    DateTime? acknowledgedAt,
    int? retentionDays,
    bool clearStateChangedAt = false,
    bool clearAcknowledgedAt = false,
    bool clearRetentionDays = false,
  }) {
    return Channel(
      slug: slug ?? this.slug,
      name: name ?? this.name,
      joinedAt: joinedAt ?? this.joinedAt,
      deviceToken: deviceToken ?? this.deviceToken,
      state: state ?? this.state,
      stateChangedAt:
          clearStateChangedAt ? null : (stateChangedAt ?? this.stateChangedAt),
      acknowledgedAt:
          clearAcknowledgedAt ? null : (acknowledgedAt ?? this.acknowledgedAt),
      retentionDays:
          clearRetentionDays ? null : (retentionDays ?? this.retentionDays),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Channel &&
          slug == other.slug &&
          name == other.name &&
          joinedAt == other.joinedAt &&
          deviceToken == other.deviceToken &&
          state == other.state &&
          stateChangedAt == other.stateChangedAt &&
          acknowledgedAt == other.acknowledgedAt &&
          retentionDays == other.retentionDays;

  @override
  int get hashCode => Object.hash(
        slug,
        name,
        joinedAt,
        deviceToken,
        state,
        stateChangedAt,
        acknowledgedAt,
        retentionDays,
      );
}
