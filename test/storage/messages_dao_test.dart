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
    // Seed an active channel for the messages to belong to.
    await db.channels.upsert(Channel(
      slug: 'alerts',
      name: 'Alerts',
      joinedAt: DateTime(2026, 1, 1),
      subscriptionId: 'sub-alerts',
    ));
  });

  tearDown(() async {
    await db.close();
  });

  Message makeMessage({
    String id = '018f0000-0000-7000-8000-000000000001',
    String channelSlug = 'alerts',
    DateTime? sentAt,
    String title = 'Hello',
    String body = 'World',
    Map<String, dynamic>? extras,
    MessagePriority priority = MessagePriority.normal,
  }) {
    return Message(
      id: id,
      channelSlug: channelSlug,
      sentAt: sentAt ?? DateTime(2026, 6, 15, 10),
      receivedAt: DateTime(2026, 6, 15, 10, 0, 1),
      title: title,
      body: body,
      priority: priority,
      extras: extras,
    );
  }

  group('MessagesDao', () {
    test('insert + findById round-trip preserves all fields', () async {
      final msg = makeMessage(
        extras: {'build': 'b-2419', 'count': 3},
        priority: MessagePriority.high,
      );
      final inserted = await db.messages.insert(msg);
      expect(inserted, isTrue);

      final fetched = await db.messages.findById(msg.id);
      expect(fetched, isNotNull);
      expect(fetched!.id, msg.id);
      expect(fetched.channelSlug, 'alerts');
      expect(fetched.title, 'Hello');
      expect(fetched.body, 'World');
      expect(fetched.priority, MessagePriority.high);
      expect(fetched.extras, equals({'build': 'b-2419', 'count': 3}));
      expect(fetched.readAt, isNull);
    });

    test('insert is idempotent on duplicate id', () async {
      final msg = makeMessage();
      expect(await db.messages.insert(msg), isTrue);
      expect(await db.messages.insert(msg), isFalse);

      final all = await db.messages.listByChannel('alerts');
      expect(all.length, 1);
    });

    test('listByChannel returns newest first', () async {
      await db.messages.insert(makeMessage(
        id: '018f0000-0000-7000-8000-000000000001',
        sentAt: DateTime(2026, 6, 15, 10),
      ));
      await db.messages.insert(makeMessage(
        id: '018f0000-0000-7000-8000-000000000002',
        sentAt: DateTime(2026, 6, 15, 11),
      ));
      await db.messages.insert(makeMessage(
        id: '018f0000-0000-7000-8000-000000000003',
        sentAt: DateTime(2026, 6, 15, 9),
      ));

      final list = await db.messages.listByChannel('alerts');
      expect(list.map((m) => m.id).toList(), [
        '018f0000-0000-7000-8000-000000000002',
        '018f0000-0000-7000-8000-000000000001',
        '018f0000-0000-7000-8000-000000000003',
      ]);
    });

    test('markRead sets read_at and is no-op on already-read', () async {
      final msg = makeMessage();
      await db.messages.insert(msg);

      final at = DateTime(2026, 6, 16);
      var rows = await db.messages.markRead(msg.id, at: at);
      expect(rows, 1);

      final fetched = await db.messages.findById(msg.id);
      expect(fetched!.readAt, at);
      expect(fetched.isRead, isTrue);

      // Second call is a no-op.
      rows = await db.messages.markRead(msg.id, at: DateTime(2026, 6, 17));
      expect(rows, 0);

      final reFetched = await db.messages.findById(msg.id);
      expect(reFetched!.readAt, at, reason: 'read_at should not be overwritten');
    });

    test('markChannelRead updates only unread messages in the channel',
        () async {
      // Two messages in 'alerts', one already read.
      await db.messages.insert(makeMessage(
        id: '018f0000-0000-7000-8000-000000000001',
      ));
      await db.messages.insert(makeMessage(
        id: '018f0000-0000-7000-8000-000000000002',
      ));
      await db.messages.markRead(
        '018f0000-0000-7000-8000-000000000001',
        at: DateTime(2026, 6, 15, 10, 5),
      );

      // A second active channel with one unread message.
      await db.channels.upsert(Channel(
        slug: 'other',
        name: 'Other',
        joinedAt: DateTime(2026, 1, 1),
        subscriptionId: 'sub-other',
      ));
      await db.messages.insert(makeMessage(
        id: '018f0000-0000-7000-8000-000000000003',
        channelSlug: 'other',
      ));

      final rows = await db.messages
          .markChannelRead('alerts', at: DateTime(2026, 6, 16));
      expect(rows, 1, reason: 'only the unread one in alerts is updated');

      expect(await db.messages.countUnread(channelSlug: 'alerts'), 0);
      expect(await db.messages.countUnread(channelSlug: 'other'), 1);
    });

    test('countUnread global and per-channel', () async {
      await db.messages.insert(makeMessage(
        id: '018f0000-0000-7000-8000-000000000001',
      ));
      await db.messages.insert(makeMessage(
        id: '018f0000-0000-7000-8000-000000000002',
      ));
      await db.messages.markRead(
        '018f0000-0000-7000-8000-000000000001',
        at: DateTime(2026, 6, 15, 10, 5),
      );

      expect(await db.messages.countUnread(), 1);
      expect(await db.messages.countUnread(channelSlug: 'alerts'), 1);
      expect(await db.messages.countUnread(channelSlug: 'unknown'), 0);
    });

    test('purgeChannel deletes all messages for the slug', () async {
      await db.messages.insert(makeMessage(
        id: '018f0000-0000-7000-8000-000000000001',
      ));
      await db.messages.insert(makeMessage(
        id: '018f0000-0000-7000-8000-000000000002',
      ));

      final rows = await db.messages.purgeChannel('alerts');
      expect(rows, 2);
      expect(await db.messages.listByChannel('alerts'), isEmpty);
    });

    test('cascade delete: removing the channel removes its messages',
        () async {
      await db.messages.insert(makeMessage());
      await db.channels.hardDelete('alerts');
      expect(
        await db.messages.findById('018f0000-0000-7000-8000-000000000001'),
        isNull,
      );
    });

    group('retentionSweep', () {
      late DateTime now;

      setUp(() {
        now = DateTime(2026, 6, 30);
      });

      Future<void> insertAged(String id, int daysAgo) async {
        await db.messages.insert(makeMessage(
          id: id,
          sentAt: now.subtract(Duration(days: daysAgo)),
        ));
      }

      test('does nothing when default retention is null', () async {
        await insertAged('018f0000-0000-7000-8000-000000000001', 100);
        final deleted = await db.messages
            .retentionSweep(now: now, defaultRetentionDays: null);
        expect(deleted, 0);
      });

      test('does nothing when default retention is 0', () async {
        await insertAged('018f0000-0000-7000-8000-000000000001', 100);
        final deleted = await db.messages
            .retentionSweep(now: now, defaultRetentionDays: 0);
        expect(deleted, 0);
      });

      test('prunes messages older than the global default', () async {
        await insertAged('018f0000-0000-7000-8000-000000000001', 5);
        await insertAged('018f0000-0000-7000-8000-000000000002', 31);
        await insertAged('018f0000-0000-7000-8000-000000000003', 365);

        final deleted = await db.messages
            .retentionSweep(now: now, defaultRetentionDays: 30);
        expect(deleted, 2);

        final remaining = await db.messages.listByChannel('alerts');
        expect(remaining.length, 1);
        expect(remaining.first.id, '018f0000-0000-7000-8000-000000000001');
      });

      test('per-channel override takes precedence over global default',
          () async {
        // Pin alerts to unlimited (0).
        await db.channels.upsert(Channel(
          slug: 'alerts',
          name: 'Alerts',
          joinedAt: DateTime(2026, 1, 1),
          subscriptionId: 'sub-alerts',
          retentionDays: 0,
        ));
        await insertAged('018f0000-0000-7000-8000-000000000001', 365);

        final deleted = await db.messages
            .retentionSweep(now: now, defaultRetentionDays: 30);
        expect(deleted, 0);
      });

      test('skips inactive channels entirely', () async {
        // Tombstoned channels should not have their messages auto-pruned —
        // their messages are wiped at revocation time, and any leftover
        // (e.g. seeded by a test) is none of the retention sweep's business.
        await db.channels.markInactive(
          'alerts',
          newState: ChannelState.deleted,
          stateChangedAt: now.subtract(const Duration(days: 1)),
        );
        await insertAged('018f0000-0000-7000-8000-000000000001', 365);

        final deleted = await db.messages
            .retentionSweep(now: now, defaultRetentionDays: 30);
        expect(deleted, 0);
      });
    });
  });
}
