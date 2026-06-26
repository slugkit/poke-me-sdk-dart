import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/channel.dart';
import '../models/message.dart';

/// Read/write access to the `messages` table.
class MessagesDao {
  MessagesDao(this._db);

  final DatabaseExecutor _db;

  /// Inserts [message]. Idempotent on duplicate id (FCM/APNs occasionally
  /// redeliver the same push). Returns true if the row was actually
  /// inserted, false if it was a duplicate.
  Future<bool> insert(Message message) async {
    final rowId = await _db.insert(
      'messages',
      _toRow(message),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return rowId != 0;
  }

  /// Returns the message with the given [id], or `null` if absent.
  Future<Message?> findById(String id) async {
    final rows = await _db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  /// Returns messages for a given channel, newest first.
  Future<List<Message>> listByChannel(
    String channelSlug, {
    int limit = 50,
    int offset = 0,
  }) async {
    final rows = await _db.query(
      'messages',
      where: 'channel_slug = ?',
      whereArgs: [channelSlug],
      orderBy: 'sent_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_fromRow).toList();
  }

  /// Cross-channel inbox: all messages, newest first.
  Future<List<Message>> listRecent({int limit = 50, int offset = 0}) async {
    final rows = await _db.query(
      'messages',
      orderBy: 'sent_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_fromRow).toList();
  }

  /// Unread messages, newest first.
  Future<List<Message>> listUnread({int limit = 50}) async {
    final rows = await _db.query(
      'messages',
      where: 'read_at IS NULL',
      orderBy: 'sent_at DESC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  /// Counts unread messages, optionally restricted to a single [channelSlug].
  Future<int> countUnread({String? channelSlug}) async {
    final rows = await _db.rawQuery(
      channelSlug == null
          ? 'SELECT COUNT(*) AS c FROM messages WHERE read_at IS NULL'
          : 'SELECT COUNT(*) AS c FROM messages WHERE read_at IS NULL AND channel_slug = ?',
      channelSlug == null ? null : [channelSlug],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  /// Marks a single message as read.
  Future<int> markRead(String id, {required DateTime at}) {
    return _db.update(
      'messages',
      {'read_at': at.millisecondsSinceEpoch},
      where: 'id = ? AND read_at IS NULL',
      whereArgs: [id],
    );
  }

  /// Marks all unread messages in [channelSlug] as read. Returns the
  /// number of rows updated.
  Future<int> markChannelRead(String channelSlug, {required DateTime at}) {
    return _db.update(
      'messages',
      {'read_at': at.millisecondsSinceEpoch},
      where: 'channel_slug = ? AND read_at IS NULL',
      whereArgs: [channelSlug],
    );
  }

  /// Deletes all messages for a channel. Used as part of the atomic
  /// revoke/delete flow — call inside the same transaction that updates
  /// the channel state. See the SDK storage layer.
  Future<int> purgeChannel(String channelSlug) {
    return _db.delete(
      'messages',
      where: 'channel_slug = ?',
      whereArgs: [channelSlug],
    );
  }

  /// Prunes messages older than the effective retention for each active
  /// channel. The effective retention is the channel's per-channel override
  /// if set, otherwise [defaultRetentionDays]. A retention of `0` or `null`
  /// means unlimited (no pruning).
  ///
  /// Returns the total number of rows deleted.
  Future<int> retentionSweep({
    required DateTime now,
    required int? defaultRetentionDays,
  }) async {
    final activeChannels = await _db.query(
      'channels',
      columns: ['slug', 'retention_days'],
      where: 'state = ?',
      whereArgs: [ChannelState.active.name],
    );

    var deleted = 0;
    for (final row in activeChannels) {
      final perChannel = row['retention_days'] as int?;
      final effective = perChannel ?? defaultRetentionDays;
      if (effective == null || effective <= 0) {
        continue; // unlimited
      }
      final cutoffMs =
          now.subtract(Duration(days: effective)).millisecondsSinceEpoch;
      deleted += await _db.delete(
        'messages',
        where: 'channel_slug = ? AND sent_at < ?',
        whereArgs: [row['slug'], cutoffMs],
      );
    }
    return deleted;
  }

  // ---------------------------------------------------------------------------
  // Mapping
  // ---------------------------------------------------------------------------

  static Map<String, Object?> _toRow(Message m) {
    return {
      'id': m.id,
      'channel_slug': m.channelSlug,
      'sent_at': m.sentAt.millisecondsSinceEpoch,
      'received_at': m.receivedAt.millisecondsSinceEpoch,
      'priority': m.priority.name,
      'title': m.title,
      'body': m.body,
      'url': m.url,
      'extras': m.extras == null ? null : jsonEncode(m.extras),
      'read_at': m.readAt?.millisecondsSinceEpoch,
      'v': m.v,
    };
  }

  static Message _fromRow(Map<String, Object?> row) {
    final extrasRaw = row['extras'] as String?;
    return Message(
      id: row['id'] as String,
      channelSlug: row['channel_slug'] as String,
      sentAt: DateTime.fromMillisecondsSinceEpoch(row['sent_at'] as int),
      receivedAt:
          DateTime.fromMillisecondsSinceEpoch(row['received_at'] as int),
      priority: MessagePriority.fromString(row['priority'] as String),
      title: row['title'] as String,
      body: row['body'] as String,
      url: row['url'] as String?,
      extras: extrasRaw == null
          ? null
          : (jsonDecode(extrasRaw) as Map<String, dynamic>),
      readAt: row['read_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row['read_at'] as int),
      v: row['v'] as int,
    );
  }
}
