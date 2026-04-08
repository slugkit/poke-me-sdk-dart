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
    required this.subscriptionId,
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

  /// Per-channel subscription identifier returned by the subscribe
  /// endpoint. Used to delete an individual subscription via
  /// `DELETE /api/v1/devices/me/subscriptions/{subscription_id}`.
  ///
  /// The device-wide auth token is a singleton, stored in `sync_state`
  /// under [SyncStateKeys.deviceToken] — not on the channel.
  final String subscriptionId;

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
    String? subscriptionId,
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
      subscriptionId: subscriptionId ?? this.subscriptionId,
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
          subscriptionId == other.subscriptionId &&
          state == other.state &&
          stateChangedAt == other.stateChangedAt &&
          acknowledgedAt == other.acknowledgedAt &&
          retentionDays == other.retentionDays;

  @override
  int get hashCode => Object.hash(
        slug,
        name,
        joinedAt,
        subscriptionId,
        state,
        stateChangedAt,
        acknowledgedAt,
        retentionDays,
      );
}
