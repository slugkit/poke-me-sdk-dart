import 'package:flutter_test/flutter_test.dart';
import 'package:pokeme/pokeme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late MessageStore store;
  late PushReceiver receiver;
  final fixedNow = DateTime(2026, 6, 20, 12);

  setUp(() async {
    store = await MessageStore.open(
      path: inMemoryDatabasePath,
      databaseFactory: databaseFactoryFfi,
    );
    receiver = PushReceiver(store: store, clock: () => fixedNow);
  });

  tearDown(() async {
    await store.close();
  });

  Future<void> joinChannel(String slug) async {
    await store.joinChannel(Channel(
      slug: slug,
      name: 'Channel $slug',
      joinedAt: DateTime(2026, 1, 1),
      subscriptionId: 'sub-$slug',
    ));
  }

  Map<String, dynamic> alertPayload({
    String id = '018f0000-0000-7000-8000-000000000001',
    String channelSlug = 'alerts',
    String title = 'Hello',
    String body = 'World',
  }) {
    return {
      'v': 1,
      'id': id,
      'sent_at': 1712345678901,
      'kind': 'alert',
      'channel_slug': channelSlug,
      'channel_name': 'Channel $channelSlug',
      'priority': 'high',
      'title': title,
      'body': body,
    };
  }

  Map<String, dynamic> systemPayload({
    String id = '018f0000-0000-7000-8000-0000000000aa',
    String channelSlug = 'alerts',
    required String event,
    Map<String, dynamic>? data,
  }) {
    return {
      'v': 1,
      'id': id,
      'sent_at': 1712345678901,
      'kind': 'system',
      'channel_slug': channelSlug,
      'event': event,
      'data': ?data,
    };
  }

  group('alerts', () {
    test('alertStored when channel is active', () async {
      await joinChannel('alerts');
      final result = await receiver.receive(alertPayload());
      expect(result, PushReceiveResult.alertStored);
      expect(await store.countUnread(), 1);
    });

    test('alertDuplicate on second receive of same id', () async {
      await joinChannel('alerts');
      await receiver.receive(alertPayload());
      final second = await receiver.receive(alertPayload());
      expect(second, PushReceiveResult.alertDuplicate);
      expect(await store.countUnread(), 1);
    });

    test('alertDropped when channel is unknown', () async {
      final result = await receiver.receive(alertPayload());
      expect(result, PushReceiveResult.alertDropped);
      expect(await store.countUnread(), 0);
    });

    test('alertDropped when channel is tombstoned', () async {
      await joinChannel('alerts');
      await store.handleChannelDeleted('alerts');

      final result = await receiver.receive(alertPayload());
      expect(result, PushReceiveResult.alertDropped);
    });

    test('stored message uses injected clock for receivedAt', () async {
      await joinChannel('alerts');
      await receiver.receive(alertPayload());

      final stored =
          await store.getMessage('018f0000-0000-7000-8000-000000000001');
      expect(stored, isNotNull);
      expect(stored!.receivedAt, fixedNow);
      expect(stored.priority, MessagePriority.high);
    });
  });

  group('system events', () {
    test('channel_renamed updates the channel name and advances cursor',
        () async {
      await joinChannel('alerts');

      final result = await receiver.receive(systemPayload(
        event: 'channel_renamed',
        data: {'new_name': 'Critical Alerts'},
      ));

      expect(result, PushReceiveResult.systemEventApplied);
      expect((await store.getChannel('alerts'))?.name, 'Critical Alerts');
      expect(
        await store.getLastSystemEventId(),
        '018f0000-0000-7000-8000-0000000000aa',
      );
    });

    test('channel_slug_changed rewrites the slug and preserves messages',
        () async {
      await joinChannel('alerts');
      await receiver.receive(alertPayload());

      final result = await receiver.receive(systemPayload(
        event: 'channel_slug_changed',
        data: {'new_slug': 'critical-alerts'},
      ));

      expect(result, PushReceiveResult.systemEventApplied);
      expect(await store.getChannel('alerts'), isNull);
      expect(await store.getChannel('critical-alerts'), isNotNull);

      final messages = await store.listMessages('critical-alerts');
      expect(messages.length, 1);
    });

    test('channel_deleted purges and tombstones', () async {
      await joinChannel('alerts');
      await receiver.receive(alertPayload());
      expect(await store.countUnread(), 1);

      final result = await receiver.receive(systemPayload(
        event: 'channel_deleted',
      ));

      expect(result, PushReceiveResult.systemEventApplied);
      expect(await store.countUnread(), 0);

      final ch = await store.getChannel('alerts');
      expect(ch, isNotNull);
      expect(ch!.state, ChannelState.deleted);
      expect(ch.stateChangedAt, fixedNow);
    });

    test('subscription_revoked purges and tombstones with revoked state',
        () async {
      await joinChannel('alerts');
      await receiver.receive(alertPayload());

      final result = await receiver.receive(systemPayload(
        event: 'subscription_revoked',
      ));

      expect(result, PushReceiveResult.systemEventApplied);
      expect(await store.listMessages('alerts'), isEmpty);
      expect((await store.getChannel('alerts'))?.state, ChannelState.revoked);
    });

    test('unknown event name returns systemEventUnknown without advancing cursor',
        () async {
      await joinChannel('alerts');

      final result = await receiver.receive(systemPayload(
        event: 'channel_archived', // not in the v1 catalogue
      ));

      expect(result, PushReceiveResult.systemEventUnknown);
      expect(await store.getLastSystemEventId(), isNull);
      // Channel state untouched.
      expect((await store.getChannel('alerts'))?.state, ChannelState.active);
    });

    test('channel_renamed without new_name returns systemEventInvalid',
        () async {
      await joinChannel('alerts');

      final result = await receiver.receive(systemPayload(
        event: 'channel_renamed',
        data: {}, // missing new_name
      ));

      expect(result, PushReceiveResult.systemEventInvalid);
      expect((await store.getChannel('alerts'))?.name, 'Channel alerts');
      expect(await store.getLastSystemEventId(), isNull);
    });

    test('channel_slug_changed without new_slug returns systemEventInvalid',
        () async {
      await joinChannel('alerts');

      final result = await receiver.receive(systemPayload(
        event: 'channel_slug_changed',
        data: {},
      ));

      expect(result, PushReceiveResult.systemEventInvalid);
      expect(await store.getChannel('alerts'), isNotNull);
      expect(await store.getLastSystemEventId(), isNull);
    });

    test('channel_renamed without any data returns systemEventInvalid',
        () async {
      await joinChannel('alerts');

      final result = await receiver.receive(systemPayload(
        event: 'channel_renamed',
        // no data at all
      ));

      expect(result, PushReceiveResult.systemEventInvalid);
    });

    test('successful system event for unknown channel still advances cursor',
        () async {
      // The store handlers no-op gracefully when the channel isn't tracked
      // locally — that's fine. The cursor advances because we processed the
      // event.
      final result = await receiver.receive(systemPayload(
        event: 'channel_renamed',
        data: {'new_name': 'Whatever'},
      ));

      expect(result, PushReceiveResult.systemEventApplied);
      expect(
        await store.getLastSystemEventId(),
        '018f0000-0000-7000-8000-0000000000aa',
      );
    });
  });

  group('parse errors', () {
    test('returns parseError on missing required field', () async {
      final raw = alertPayload()..remove('id');
      final result = await receiver.receive(raw);
      expect(result, PushReceiveResult.parseError);
    });

    test('returns parseError on invalid kind', () async {
      final raw = alertPayload()..['kind'] = 'banana';
      final result = await receiver.receive(raw);
      expect(result, PushReceiveResult.parseError);
    });

    test('parseError does not advance cursor', () async {
      await receiver.receive(alertPayload()..remove('id'));
      expect(await store.getLastSystemEventId(), isNull);
    });
  });
}
