import 'package:flutter_test/flutter_test.dart';
import 'package:pokeme/channels.dart';
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

  Channel makeChannel({
    String slug = 'alerts',
    String name = 'Alerts',
    ChannelState state = ChannelState.active,
  }) {
    return Channel(
      slug: slug,
      name: name,
      joinedAt: DateTime(2026, 1, 1),
      subscriptionId: 'sub-$slug',
      state: state,
    );
  }

  group('ChannelsDao', () {
    test('upsert + findBySlug round-trip', () async {
      await db.channels.upsert(makeChannel());

      final fetched = await db.channels.findBySlug('alerts');
      expect(fetched, isNotNull);
      expect(fetched!.slug, 'alerts');
      expect(fetched.name, 'Alerts');
      expect(fetched.state, ChannelState.active);
      expect(fetched.subscriptionId, 'sub-alerts');
    });

    test('findBySlug returns null for unknown slug', () async {
      final fetched = await db.channels.findBySlug('nope');
      expect(fetched, isNull);
    });

    test('list with state filter', () async {
      await db.channels.upsert(makeChannel(slug: 'a'));
      await db.channels.upsert(makeChannel(slug: 'b'));
      await db.channels
          .upsert(makeChannel(slug: 'c', state: ChannelState.deleted));

      final active = await db.channels.list(state: ChannelState.active);
      expect(active.map((c) => c.slug), unorderedEquals(['a', 'b']));

      final all = await db.channels.list();
      expect(all.length, 3);
    });

    test('rename updates only the name field', () async {
      await db.channels.upsert(makeChannel());
      await db.channels.rename('alerts', 'New Alerts');

      final fetched = await db.channels.findBySlug('alerts');
      expect(fetched!.name, 'New Alerts');
      expect(fetched.slug, 'alerts');
    });

    test('changeSlug updates the primary key', () async {
      await db.channels.upsert(makeChannel());
      await db.channels.changeSlug('alerts', 'critical-alerts');

      expect(await db.channels.findBySlug('alerts'), isNull);
      final fetched = await db.channels.findBySlug('critical-alerts');
      expect(fetched, isNotNull);
      expect(fetched!.name, 'Alerts');
    });

    test('markInactive sets state and stateChangedAt', () async {
      await db.channels.upsert(makeChannel());
      final at = DateTime(2026, 6, 15);
      await db.channels.markInactive(
        'alerts',
        newState: ChannelState.deleted,
        stateChangedAt: at,
      );

      final fetched = await db.channels.findBySlug('alerts');
      expect(fetched!.state, ChannelState.deleted);
      expect(fetched.stateChangedAt, at);
      expect(fetched.acknowledgedAt, isNull);
    });

    test('acknowledge only affects inactive channels', () async {
      await db.channels.upsert(makeChannel());
      final ack = DateTime(2026, 6, 16);

      // Active channel should not be acknowledged.
      var rows = await db.channels.acknowledge('alerts', at: ack);
      expect(rows, 0);

      // Move to deleted then acknowledge.
      await db.channels.markInactive(
        'alerts',
        newState: ChannelState.deleted,
        stateChangedAt: DateTime(2026, 6, 15),
      );
      rows = await db.channels.acknowledge('alerts', at: ack);
      expect(rows, 1);

      final fetched = await db.channels.findBySlug('alerts');
      expect(fetched!.acknowledgedAt, ack);
    });

    test('findExpiredTombstones returns acknowledged tombstones older than cutoff',
        () async {
      // Three deleted channels with different acknowledgement times.
      final now = DateTime(2026, 6, 20);
      final fresh = now.subtract(const Duration(hours: 1));
      final stale = now.subtract(const Duration(days: 2));

      for (final slug in ['fresh', 'stale', 'unack']) {
        await db.channels.upsert(makeChannel(slug: slug));
        await db.channels.markInactive(
          slug,
          newState: ChannelState.deleted,
          stateChangedAt: now.subtract(const Duration(days: 5)),
        );
      }
      await db.channels.acknowledge('fresh', at: fresh);
      await db.channels.acknowledge('stale', at: stale);
      // 'unack' is intentionally never acknowledged.

      final expired = await db.channels.findExpiredTombstones(
        now: now,
        maxAge: const Duration(days: 1),
      );
      expect(expired, equals(['stale']));
    });

    test('hardDelete removes the channel', () async {
      await db.channels.upsert(makeChannel());
      await db.channels.hardDelete('alerts');
      expect(await db.channels.findBySlug('alerts'), isNull);
    });
  });
}
