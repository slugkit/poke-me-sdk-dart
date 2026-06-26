import 'package:flutter_test/flutter_test.dart';
import 'package:pokeme/pokeme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  Future<PokemeDatabase> openInMemory() {
    return PokemeDatabase.open(
      path: inMemoryDatabasePath,
      databaseFactory: databaseFactoryFfi,
    );
  }

  group('PokemeDatabase', () {
    test('open creates schema at the latest version', () async {
      final db = await openInMemory();
      addTearDown(db.close);

      final result =
          await db.raw.rawQuery('PRAGMA user_version');
      expect(result.first.values.first, equals(1));
    });

    test('open creates all tables', () async {
      final db = await openInMemory();
      addTearDown(db.close);

      final tables = await db.raw.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
      );
      final names = tables.map((r) => r['name']).toList();
      expect(names, containsAll(['channels', 'messages', 'sync_state']));
    });

    test('foreign keys are enabled', () async {
      final db = await openInMemory();
      addTearDown(db.close);

      final result = await db.raw.rawQuery('PRAGMA foreign_keys');
      expect(result.first.values.first, equals(1));
    });
  });
}
