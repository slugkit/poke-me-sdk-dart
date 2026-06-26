import 'package:sqflite/sqflite.dart';

/// A single schema migration.
///
/// Migrations are applied in order. The current schema version is tracked
/// via SQLite's `PRAGMA user_version`.
class Migration {
  const Migration({required this.version, required this.statements});

  /// The version this migration brings the database to. Must be strictly
  /// greater than the previous migration's version.
  final int version;

  /// SQL statements applied as part of this migration. Executed in order
  /// inside a transaction.
  final List<String> statements;
}

/// Ordered list of all schema migrations.
///
/// Append-only — never modify a published migration. To change the schema,
/// add a new migration with the next version number.
const List<Migration> migrations = [
  Migration(
    version: 1,
    statements: [
      // Channels: denormalised state for each channel the device is or was
      // subscribed to.
      //
      // The device_id and device_token (returned by the subscribe endpoint)
      // are device-wide singletons and live in sync_state. The per-channel
      // subscription_id is what's needed to delete a single subscription
      // via DELETE /api/v1/devices/me/subscriptions/{sub_ref}.
      '''
      CREATE TABLE channels (
        slug              TEXT PRIMARY KEY,
        name              TEXT NOT NULL,
        joined_at         INTEGER NOT NULL,
        subscription_id   TEXT NOT NULL,
        state             TEXT NOT NULL
                              CHECK (state IN ('active', 'revoked', 'deleted')),
        state_changed_at  INTEGER,
        acknowledged_at   INTEGER,
        retention_days    INTEGER
      )
      ''',

      // Messages: received user-facing alerts.
      //
      // ON UPDATE CASCADE so a channel slug rename (handled by the
      // channel_slug_changed system event) propagates to all linked
      // messages without manual intervention.
      '''
      CREATE TABLE messages (
        id            TEXT PRIMARY KEY,
        channel_slug  TEXT NOT NULL REFERENCES channels(slug)
                          ON DELETE CASCADE
                          ON UPDATE CASCADE,
        sent_at       INTEGER NOT NULL,
        received_at   INTEGER NOT NULL,
        priority      TEXT NOT NULL
                          CHECK (priority IN ('low', 'normal', 'high', 'critical')),
        title         TEXT NOT NULL,
        body          TEXT NOT NULL,
        url           TEXT,
        extras        TEXT,
        read_at       INTEGER,
        v             INTEGER NOT NULL
      )
      ''',

      // Primary "messages in channel, newest first" query.
      '''
      CREATE INDEX messages_by_channel_recent
        ON messages (channel_slug, sent_at DESC)
      ''',

      // Cross-channel inbox view.
      '''
      CREATE INDEX messages_by_recent
        ON messages (sent_at DESC)
      ''',

      // Fast unread badge counts.
      '''
      CREATE INDEX messages_unread
        ON messages (channel_slug)
        WHERE read_at IS NULL
      ''',

      // Sync state: key/value bag for SDK bookkeeping.
      '''
      CREATE TABLE sync_state (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
      ''',
    ],
  ),
];

/// The latest schema version. Equal to the version of the last migration.
int get latestSchemaVersion => migrations.last.version;

/// Applies any migrations whose version is strictly greater than [from]
/// and less than or equal to [to]. Each migration runs inside its own
/// transaction; partial application of a single migration is not possible.
Future<void> applyMigrations(
  Database db, {
  required int from,
  required int to,
}) async {
  for (final migration in migrations) {
    if (migration.version <= from || migration.version > to) {
      continue;
    }
    await db.transaction((txn) async {
      for (final statement in migration.statements) {
        await txn.execute(statement);
      }
      await txn.execute('PRAGMA user_version = ${migration.version}');
    });
  }
}
