import 'package:flutter_test/flutter_test.dart';
import 'package:pokeme/pokeme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late PokemeDatabase db;

  setUp(() async {
    db = await PokemeDatabase.open(
      path: inMemoryDatabasePath,
      databaseFactory: databaseFactoryFfi,
    );
  });

  tearDown(() async {
    await db.close();
  });

  group('SyncStateDao', () {
    test('get returns null for missing key', () async {
      expect(await db.syncState.get('nope'), isNull);
    });

    test('set + get round-trip', () async {
      await db.syncState.set(SyncStateKeys.lastSystemEventId, '018f-abc');
      expect(
        await db.syncState.get(SyncStateKeys.lastSystemEventId),
        '018f-abc',
      );
    });

    test('set replaces existing value', () async {
      await db.syncState.set('k', 'first');
      await db.syncState.set('k', 'second');
      expect(await db.syncState.get('k'), 'second');
    });

    test('setInt and getInt', () async {
      await db.syncState.setInt(SyncStateKeys.defaultRetentionDays, 30);
      expect(
        await db.syncState.getInt(SyncStateKeys.defaultRetentionDays),
        30,
      );
    });

    test('getInt returns null for unparseable value', () async {
      await db.syncState.set('weird', 'not a number');
      expect(await db.syncState.getInt('weird'), isNull);
    });

    test('remove deletes the key', () async {
      await db.syncState.set('k', 'v');
      await db.syncState.remove('k');
      expect(await db.syncState.get('k'), isNull);
    });
  });
}
