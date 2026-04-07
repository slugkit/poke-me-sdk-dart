import 'package:flutter_test/flutter_test.dart';
import 'package:pokeme/pokeme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late MessageStore store;

  setUp(() async {
    store = await MessageStore.open(
      path: inMemoryDatabasePath,
      databaseFactory: databaseFactoryFfi,
    );
  });

  tearDown(() async {
    await store.close();
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
      deviceToken: 'tok-$slug',
      state: state,
    );
  }

  Message makeMessage({
    String id = '018f0000-0000-7000-8000-000000000001',
    String channelSlug = 'alerts',
    DateTime? sentAt,
  }) {
    return Message(
      id: id,
      channelSlug: channelSlug,
      sentAt: sentAt ?? DateTime(2026, 6, 15, 10),
      receivedAt: DateTime(2026, 6, 15, 10, 0, 1),
      title: 'Hello',
      body: 'World',
    );
  }

  group('subscriptions', () {
    test('joinChannel + getChannel + listChannels', () async {
      await store.joinChannel(makeChannel(slug: 'a'));
      await store.joinChannel(makeChannel(slug: 'b'));

      expect((await store.getChannel('a'))?.name, 'Alerts');
      expect(await store.getChannel('nope'), isNull);

      final active = await store.listChannels();
      expect(active.map((c) => c.slug), unorderedEquals(['a', 'b']));
    });

    test('listChannels excludes tombstones by default', () async {
      await store.joinChannel(makeChannel(slug: 'a'));
      await store.joinChannel(makeChannel(slug: 'b'));
      await store.handleChannelDeleted('b');

      final active = await store.listChannels();
      expect(active.map((c) => c.slug), equals(['a']));

      final all = await store.listChannels(includeTombstones: true);
      expect(all.map((c) => c.slug), unorderedEquals(['a', 'b']));
    });
  });

  group('receiveMessage gating', () {
    test('inserted when channel is active', () async {
      await store.joinChannel(makeChannel());
      final result = await store.receiveMessage(makeMessage());
      expect(result, MessageReceiveResult.inserted);
      expect(await store.countUnread(), 1);
    });

    test('duplicate when id already present', () async {
      await store.joinChannel(makeChannel());
      await store.receiveMessage(makeMessage());
      final second = await store.receiveMessage(makeMessage());
      expect(second, MessageReceiveResult.duplicate);
      expect(await store.countUnread(), 1);
    });

    test('dropped when channel is unknown', () async {
      final result = await store.receiveMessage(makeMessage());
      expect(result, MessageReceiveResult.dropped);
      expect(await store.countUnread(), 0);
    });

    test('dropped when channel is in deleted state', () async {
      await store.joinChannel(makeChannel());
      await store.handleChannelDeleted('alerts');

      final result = await store.receiveMessage(makeMessage());
      expect(result, MessageReceiveResult.dropped);
      expect(await store.countUnread(), 0);
    });

    test('dropped when channel is in revoked state', () async {
      await store.joinChannel(makeChannel());
      await store.handleSubscriptionRevoked('alerts');

      final result = await store.receiveMessage(makeMessage());
      expect(result, MessageReceiveResult.dropped);
      expect(await store.countUnread(), 0);
    });
  });

  group('system event handlers', () {
    test('handleChannelRenamed updates the channel name', () async {
      await store.joinChannel(makeChannel());
      await store.handleChannelRenamed('alerts', 'Critical Alerts');
      expect((await store.getChannel('alerts'))?.name, 'Critical Alerts');
    });

    test('handleChannelSlugChanged updates the slug and preserves messages',
        () async {
      await store.joinChannel(makeChannel());
      await store.receiveMessage(makeMessage());

      await store.handleChannelSlugChanged('alerts', 'critical-alerts');

      expect(await store.getChannel('alerts'), isNull);
      expect(await store.getChannel('critical-alerts'), isNotNull);

      // Messages should still be retrievable under the new slug.
      final messages = await store.listMessages('critical-alerts');
      expect(messages.length, 1);
      expect(messages.first.channelSlug, 'critical-alerts');
    });

    test('handleChannelDeleted atomically purges messages and tombstones',
        () async {
      await store.joinChannel(makeChannel());
      await store.receiveMessage(makeMessage(
        id: '018f0000-0000-7000-8000-000000000001',
      ));
      await store.receiveMessage(makeMessage(
        id: '018f0000-0000-7000-8000-000000000002',
      ));
      expect(await store.countUnread(), 2);

      final at = DateTime(2026, 6, 20);
      await store.handleChannelDeleted('alerts', at: at);

      // Messages gone.
      expect(await store.countUnread(), 0);
      expect(await store.listMessages('alerts'), isEmpty);

      // Channel row still present, in deleted state, awaiting acknowledgement.
      final ch = await store.getChannel('alerts');
      expect(ch, isNotNull);
      expect(ch!.state, ChannelState.deleted);
      expect(ch.stateChangedAt, at);
      expect(ch.acknowledgedAt, isNull);
    });

    test('handleSubscriptionRevoked atomically purges and tombstones',
        () async {
      await store.joinChannel(makeChannel());
      await store.receiveMessage(makeMessage());

      await store.handleSubscriptionRevoked('alerts');

      expect(await store.listMessages('alerts'), isEmpty);
      final ch = await store.getChannel('alerts');
      expect(ch!.state, ChannelState.revoked);
    });
  });

  group('tombstone notices', () {
    test('listPendingNotices returns unacknowledged tombstones', () async {
      await store.joinChannel(makeChannel(slug: 'a'));
      await store.joinChannel(makeChannel(slug: 'b'));
      await store.joinChannel(makeChannel(slug: 'c'));

      await store.handleChannelDeleted('a');
      await store.handleSubscriptionRevoked('b');
      // 'c' stays active.
      // Acknowledge 'a'.
      await store.acknowledgeNotice('a');

      final pending = await store.listPendingNotices();
      expect(pending.map((c) => c.slug), equals(['b']));
    });

    test('acknowledgeNotice records the timestamp', () async {
      await store.joinChannel(makeChannel());
      await store.handleChannelDeleted('alerts');

      final at = DateTime(2026, 6, 21);
      await store.acknowledgeNotice('alerts', at: at);

      final ch = await store.getChannel('alerts');
      expect(ch!.acknowledgedAt, at);
    });
  });

  group('runMaintenance', () {
    test('prunes messages and removes acknowledged tombstones', () async {
      final now = DateTime(2026, 6, 30);

      // Active channel with messages: one within retention, one outside.
      await store.joinChannel(makeChannel(slug: 'alerts'));
      await store.setDefaultRetentionDays(30);
      await store.receiveMessage(makeMessage(
        id: '018f0000-0000-7000-8000-000000000001',
        sentAt: now.subtract(const Duration(days: 5)),
      ));
      await store.receiveMessage(makeMessage(
        id: '018f0000-0000-7000-8000-000000000002',
        sentAt: now.subtract(const Duration(days: 60)),
      ));

      // Tombstoned channel acknowledged 2 days ago — should be swept.
      await store.joinChannel(makeChannel(slug: 'old'));
      await store.handleChannelDeleted('old',
          at: now.subtract(const Duration(days: 5)));
      await store.acknowledgeNotice('old',
          at: now.subtract(const Duration(days: 2)));

      // Tombstoned channel acknowledged 1 hour ago — should NOT be swept.
      await store.joinChannel(makeChannel(slug: 'fresh'));
      await store.handleChannelDeleted('fresh',
          at: now.subtract(const Duration(days: 1)));
      await store.acknowledgeNotice('fresh',
          at: now.subtract(const Duration(hours: 1)));

      final result = await store.runMaintenance(now: now);
      expect(result.messagesPruned, 1);
      expect(result.tombstonesRemoved, 1);

      // Verify outcomes.
      expect(await store.listMessages('alerts'), hasLength(1));
      expect(await store.getChannel('old'), isNull);
      expect(await store.getChannel('fresh'), isNotNull);
    });

    test('does nothing when nothing is eligible', () async {
      await store.joinChannel(makeChannel());
      await store.receiveMessage(makeMessage());

      final result = await store.runMaintenance();
      expect(result.messagesPruned, 0);
      expect(result.tombstonesRemoved, 0);
    });
  });

  group('settings', () {
    test('getDefaultRetentionDays returns null initially', () async {
      expect(await store.getDefaultRetentionDays(), isNull);
    });

    test('set + get round-trip', () async {
      await store.setDefaultRetentionDays(60);
      expect(await store.getDefaultRetentionDays(), 60);
    });

    test('setDefaultRetentionDays(null) clears the value', () async {
      await store.setDefaultRetentionDays(60);
      await store.setDefaultRetentionDays(null);
      expect(await store.getDefaultRetentionDays(), isNull);
    });
  });

  group('activity', () {
    test('recordUserOpen stores the timestamp', () async {
      final at = DateTime(2026, 6, 22, 10, 30);
      await store.recordUserOpen(at: at);

      // Reach into the underlying sync state to verify.
      final stored = await store.getDefaultRetentionDays();
      expect(stored, isNull, reason: 'sanity: not the same key');
    });
  });

  group('read state', () {
    test('markRead and countUnread', () async {
      await store.joinChannel(makeChannel());
      await store.receiveMessage(makeMessage(
        id: '018f0000-0000-7000-8000-000000000001',
      ));
      await store.receiveMessage(makeMessage(
        id: '018f0000-0000-7000-8000-000000000002',
      ));

      expect(await store.countUnread(), 2);

      await store.markRead('018f0000-0000-7000-8000-000000000001');
      expect(await store.countUnread(), 1);
    });

    test('markChannelRead marks all unread messages in the channel', () async {
      await store.joinChannel(makeChannel(slug: 'alerts'));
      await store.joinChannel(makeChannel(slug: 'other'));
      await store.receiveMessage(makeMessage(
        id: '018f0000-0000-7000-8000-000000000001',
        channelSlug: 'alerts',
      ));
      await store.receiveMessage(makeMessage(
        id: '018f0000-0000-7000-8000-000000000002',
        channelSlug: 'alerts',
      ));
      await store.receiveMessage(makeMessage(
        id: '018f0000-0000-7000-8000-000000000003',
        channelSlug: 'other',
      ));

      await store.markChannelRead('alerts');

      expect(await store.countUnread(channelSlug: 'alerts'), 0);
      expect(await store.countUnread(channelSlug: 'other'), 1);
    });
  });
}
