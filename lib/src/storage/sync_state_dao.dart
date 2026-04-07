import 'package:sqflite/sqflite.dart';

/// Well-known keys stored in the `sync_state` table.
///
/// New keys can be added freely without a schema migration. Document each one
/// here so the SDK has a single source of truth for what's stored.
class SyncStateKeys {
  SyncStateKeys._();

  /// UUIDv7 of the last successfully processed system event. Used as the
  /// cursor for `/api/device/events?since={id}` reconciliation.
  static const lastSystemEventId = 'last_system_event_id';

  /// Unix ms of the last reconciliation call. Used for throttling.
  static const lastReconcileAt = 'last_reconcile_at';

  /// User-set global default for message retention, in days.
  /// Absent or `0` means unlimited.
  static const defaultRetentionDays = 'default_retention_days';

  /// Unix ms; updated whenever the user opens the app. Used by the tombstone
  /// sweep to decide when to acknowledge pending deletion notices.
  static const lastUserOpenAt = 'last_user_open_at';
}

/// Read/write access to the `sync_state` key/value table.
class SyncStateDao {
  SyncStateDao(this._db);

  final DatabaseExecutor _db;

  /// Returns the value stored under [key], or `null` if absent.
  Future<String?> get(String key) async {
    final rows = await _db.query(
      'sync_state',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  /// Returns the value parsed as an integer, or `null` if absent or unparseable.
  Future<int?> getInt(String key) async {
    final value = await get(key);
    if (value == null) return null;
    return int.tryParse(value);
  }

  /// Inserts or replaces [key] with [value].
  Future<void> set(String key, String value) async {
    await _db.insert(
      'sync_state',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Convenience for storing an integer.
  Future<void> setInt(String key, int value) => set(key, value.toString());

  /// Removes [key] if present. No-op if absent.
  Future<void> remove(String key) async {
    await _db.delete('sync_state', where: 'key = ?', whereArgs: [key]);
  }
}
