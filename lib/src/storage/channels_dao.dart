import 'package:sqflite/sqflite.dart';

import '../models/channel.dart';

/// Read/write access to the `channels` table.
class ChannelsDao {
  ChannelsDao(this._db);

  final DatabaseExecutor _db;

  /// Inserts or replaces a channel.
  Future<void> upsert(Channel channel) async {
    await _db.insert(
      'channels',
      _toRow(channel),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Returns the channel with the given [slug], or `null` if absent.
  Future<Channel?> findBySlug(String slug) async {
    final rows = await _db.query(
      'channels',
      where: 'slug = ?',
      whereArgs: [slug],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Returns all channels matching [state], newest first by `joined_at`.
  /// If [state] is null, returns all channels regardless of state.
  Future<List<Channel>> list({ChannelState? state}) async {
    final rows = await _db.query(
      'channels',
      where: state == null ? null : 'state = ?',
      whereArgs: state == null ? null : [state.name],
      orderBy: 'joined_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Renames a channel. Used by the `channel_renamed` system event handler.
  Future<int> rename(String slug, String newName) {
    return _db.update(
      'channels',
      {'name': newName},
      where: 'slug = ?',
      whereArgs: [slug],
    );
  }

  /// Replaces a channel's slug. Used by the `channel_slug_changed`
  /// system event handler.
  ///
  /// Because `messages.channel_slug` is a foreign key to `channels.slug`
  /// with `ON DELETE CASCADE`, sqlite handles the cascade automatically
  /// when the primary key is updated (provided foreign keys are enabled
  /// at connect time, which they are).
  Future<int> changeSlug(String oldSlug, String newSlug) {
    return _db.update(
      'channels',
      {'slug': newSlug},
      where: 'slug = ?',
      whereArgs: [oldSlug],
    );
  }

  /// Marks a channel as [ChannelState.revoked] or [ChannelState.deleted].
  ///
  /// **Does not delete messages.** The caller is responsible for wiping
  /// messages atomically with the state change — use
  /// [MessagesDao.purgeChannelOnRevocation] inside a transaction.
  Future<int> markInactive(
    String slug, {
    required ChannelState newState,
    required DateTime stateChangedAt,
  }) {
    assert(
      newState != ChannelState.active,
      'markInactive must move the channel out of the active state',
    );
    return _db.update(
      'channels',
      {
        'state': newState.name,
        'state_changed_at': stateChangedAt.millisecondsSinceEpoch,
      },
      where: 'slug = ?',
      whereArgs: [slug],
    );
  }

  /// Marks the deletion/revocation notice as acknowledged by the user.
  /// Starts the one-day clock until the channel row is hard-deleted by
  /// the tombstone sweep.
  Future<int> acknowledge(String slug, {required DateTime at}) {
    return _db.update(
      'channels',
      {'acknowledged_at': at.millisecondsSinceEpoch},
      where: 'slug = ? AND state != ?',
      whereArgs: [slug, ChannelState.active.name],
    );
  }

  /// Hard-deletes the channel row. The `ON DELETE CASCADE` on
  /// `messages.channel_slug` removes any leftover messages — though
  /// in practice messages were already wiped when the channel went
  /// inactive.
  Future<int> hardDelete(String slug) {
    return _db.delete(
      'channels',
      where: 'slug = ?',
      whereArgs: [slug],
    );
  }

  /// Returns channels in a non-active state that have not yet been
  /// acknowledged by the user. The UI uses this to show pending
  /// "this channel is gone" notices on app launch.
  Future<List<Channel>> findPendingNotices() async {
    final rows = await _db.query(
      'channels',
      where: 'state != ? AND acknowledged_at IS NULL',
      whereArgs: [ChannelState.active.name],
      orderBy: 'state_changed_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  /// Returns the slugs of channels eligible for tombstone sweep removal:
  /// non-active, with an acknowledgement timestamp older than [maxAge].
  Future<List<String>> findExpiredTombstones({
    required DateTime now,
    required Duration maxAge,
  }) async {
    final cutoff = now.subtract(maxAge).millisecondsSinceEpoch;
    final rows = await _db.query(
      'channels',
      columns: ['slug'],
      where: 'state != ? AND acknowledged_at IS NOT NULL AND acknowledged_at < ?',
      whereArgs: [ChannelState.active.name, cutoff],
    );
    return rows.map((r) => r['slug'] as String).toList();
  }

  // ---------------------------------------------------------------------------
  // Mapping
  // ---------------------------------------------------------------------------

  static Map<String, Object?> _toRow(Channel c) {
    return {
      'slug': c.slug,
      'name': c.name,
      'joined_at': c.joinedAt.millisecondsSinceEpoch,
      'device_token': c.deviceToken,
      'state': c.state.name,
      'state_changed_at': c.stateChangedAt?.millisecondsSinceEpoch,
      'acknowledged_at': c.acknowledgedAt?.millisecondsSinceEpoch,
      'retention_days': c.retentionDays,
    };
  }

  static Channel _fromRow(Map<String, Object?> row) {
    return Channel(
      slug: row['slug'] as String,
      name: row['name'] as String,
      joinedAt: DateTime.fromMillisecondsSinceEpoch(row['joined_at'] as int),
      deviceToken: row['device_token'] as String,
      state: ChannelState.fromString(row['state'] as String),
      stateChangedAt: row['state_changed_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row['state_changed_at'] as int),
      acknowledgedAt: row['acknowledged_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row['acknowledged_at'] as int),
      retentionDays: row['retention_days'] as int?,
    );
  }
}
