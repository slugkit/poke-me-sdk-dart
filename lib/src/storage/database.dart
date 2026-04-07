import 'package:sqflite/sqflite.dart';

import 'channels_dao.dart';
import 'messages_dao.dart';
import 'migrations.dart';
import 'sync_state_dao.dart';

/// The local SQLite database used by the pokeme SDK.
///
/// Stores channel subscriptions, received user-facing alert messages, and
/// SDK bookkeeping. See `design-docs/mobile/STORAGE.md` for the schema and
/// retention rules.
class PokemeDatabase {
  PokemeDatabase._(this._db);

  final Database _db;

  /// Underlying [Database] handle. Exposed for tests and advanced use cases
  /// (e.g. running ad-hoc queries). Prefer the DAO accessors for everything else.
  Database get raw => _db;

  late final ChannelsDao channels = ChannelsDao(_db);
  late final MessagesDao messages = MessagesDao(_db);
  late final SyncStateDao syncState = SyncStateDao(_db);

  /// Opens the database at [path], creating and migrating as needed.
  ///
  /// In production code, [path] should come from
  /// `path_provider.getApplicationDocumentsDirectory()`. In tests, pass
  /// `inMemoryDatabasePath` (from `sqflite_common_ffi`) or a temporary file.
  ///
  /// [databaseFactory] lets tests inject `databaseFactoryFfi` from
  /// `sqflite_common_ffi`. In production it defaults to sqflite's platform
  /// implementation.
  static Future<PokemeDatabase> open({
    required String path,
    DatabaseFactory? databaseFactory,
  }) async {
    final factory = databaseFactory ?? sqfliteDatabaseFactoryDefault;
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: latestSchemaVersion,
        onConfigure: _onConfigure,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
    return PokemeDatabase._(db);
  }

  /// Closes the underlying database. After calling this, the instance must
  /// not be used.
  Future<void> close() => _db.close();

  static Future<void> _onConfigure(Database db) async {
    // Required for the ON DELETE CASCADE between messages and channels.
    await db.execute('PRAGMA foreign_keys = ON');
  }

  static Future<void> _onCreate(Database db, int version) async {
    await applyMigrations(db, from: 0, to: version);
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    await applyMigrations(db, from: oldVersion, to: newVersion);
  }
}

/// Sqflite's platform-default database factory. Wrapped in a getter so it
/// is only resolved when an explicit factory wasn't provided — keeps tests
/// using `sqflite_common_ffi` from accidentally pulling in the platform
/// implementation.
DatabaseFactory get sqfliteDatabaseFactoryDefault => databaseFactory;
