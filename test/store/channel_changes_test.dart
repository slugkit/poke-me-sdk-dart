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
  }) {
    return Channel(
      slug: slug,
      name: name,
      joinedAt: DateTime(2026, 1, 1),
      deviceToken: 'tok-$slug',
    );
  }

  group('channelChanges stream', () {
    test('joinChannel emits ChannelJoinedEvent', () async {
      final events = <ChannelStateChange>[];
      final sub = store.channelChanges.listen(events.add);

      await store.joinChannel(makeChannel());
      await Future<void>.delayed(Duration.zero); // let the event propagate

      expect(events, hasLength(1));
      expect(events.first, isA<ChannelJoinedEvent>());
      final event = events.first as ChannelJoinedEvent;
      expect(event.channel.slug, 'alerts');

      await sub.cancel();
    });

    test('handleChannelRenamed emits ChannelRenamedEvent', () async {
      await store.joinChannel(makeChannel());

      final events = <ChannelStateChange>[];
      final sub = store.channelChanges.listen(events.add);

      await store.handleChannelRenamed('alerts', 'Critical Alerts');
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first, isA<ChannelRenamedEvent>());
      final event = events.first as ChannelRenamedEvent;
      expect(event.slug, 'alerts');
      expect(event.newName, 'Critical Alerts');

      await sub.cancel();
    });

    test('handleChannelRenamed emits nothing for unknown channel', () async {
      final events = <ChannelStateChange>[];
      final sub = store.channelChanges.listen(events.add);

      await store.handleChannelRenamed('nope', 'New Name');
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
      await sub.cancel();
    });

    test('handleChannelSlugChanged emits ChannelSlugChangedEvent', () async {
      await store.joinChannel(makeChannel());

      final events = <ChannelStateChange>[];
      final sub = store.channelChanges.listen(events.add);

      await store.handleChannelSlugChanged('alerts', 'critical-alerts');
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first, isA<ChannelSlugChangedEvent>());
      final event = events.first as ChannelSlugChangedEvent;
      expect(event.oldSlug, 'alerts');
      expect(event.newSlug, 'critical-alerts');

      await sub.cancel();
    });

    test('handleChannelSlugChanged emits nothing for unknown channel',
        () async {
      final events = <ChannelStateChange>[];
      final sub = store.channelChanges.listen(events.add);

      await store.handleChannelSlugChanged('nope', 'whatever');
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
      await sub.cancel();
    });

    test('handleChannelDeleted emits ChannelDeletedEvent', () async {
      await store.joinChannel(makeChannel());

      final events = <ChannelStateChange>[];
      final sub = store.channelChanges.listen(events.add);

      await store.handleChannelDeleted('alerts');
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first, isA<ChannelDeletedEvent>());
      expect((events.first as ChannelDeletedEvent).slug, 'alerts');

      await sub.cancel();
    });

    test('handleSubscriptionRevoked emits ChannelRevokedEvent', () async {
      await store.joinChannel(makeChannel());

      final events = <ChannelStateChange>[];
      final sub = store.channelChanges.listen(events.add);

      await store.handleSubscriptionRevoked('alerts');
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first, isA<ChannelRevokedEvent>());
      expect((events.first as ChannelRevokedEvent).slug, 'alerts');

      await sub.cancel();
    });

    test('handleChannelDeleted emits nothing for unknown channel', () async {
      final events = <ChannelStateChange>[];
      final sub = store.channelChanges.listen(events.add);

      await store.handleChannelDeleted('nope');
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty);
      await sub.cancel();
    });

    test('runMaintenance emits ChannelPurgedEvent for swept tombstones',
        () async {
      final now = DateTime(2026, 6, 30);
      await store.joinChannel(makeChannel(slug: 'old'));
      await store.handleChannelDeleted(
        'old',
        at: now.subtract(const Duration(days: 5)),
      );
      await store.acknowledgeNotice(
        'old',
        at: now.subtract(const Duration(days: 2)),
      );

      final events = <ChannelStateChange>[];
      final sub = store.channelChanges.listen(events.add);

      await store.runMaintenance(now: now);
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.first, isA<ChannelPurgedEvent>());
      expect((events.first as ChannelPurgedEvent).slug, 'old');

      await sub.cancel();
    });

    test('events fire in operation order', () async {
      final events = <ChannelStateChange>[];
      final sub = store.channelChanges.listen(events.add);

      await store.joinChannel(makeChannel(slug: 'a'));
      await store.joinChannel(makeChannel(slug: 'b'));
      await store.handleChannelRenamed('a', 'A renamed');
      await store.handleChannelSlugChanged('b', 'b2');
      await store.handleChannelDeleted('a');
      await Future<void>.delayed(Duration.zero);

      expect(events.map((e) => e.runtimeType.toString()).toList(), [
        'ChannelJoinedEvent',
        'ChannelJoinedEvent',
        'ChannelRenamedEvent',
        'ChannelSlugChangedEvent',
        'ChannelDeletedEvent',
      ]);

      await sub.cancel();
    });

    test('multiple subscribers receive the same events', () async {
      final eventsA = <ChannelStateChange>[];
      final eventsB = <ChannelStateChange>[];
      final subA = store.channelChanges.listen(eventsA.add);
      final subB = store.channelChanges.listen(eventsB.add);

      await store.joinChannel(makeChannel());
      await Future<void>.delayed(Duration.zero);

      expect(eventsA, hasLength(1));
      expect(eventsB, hasLength(1));

      await subA.cancel();
      await subB.cancel();
    });

    test('late subscribers do not receive past events', () async {
      await store.joinChannel(makeChannel());

      final events = <ChannelStateChange>[];
      final sub = store.channelChanges.listen(events.add);
      await Future<void>.delayed(Duration.zero);

      expect(events, isEmpty,
          reason: 'broadcast streams do not replay past events');

      await sub.cancel();
    });
  });
}
