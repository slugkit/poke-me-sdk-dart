import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pokeme/pokeme.dart';

Map<String, dynamic> _subjectAlert({
  String id = '018f0000-0000-7000-8000-0000000000b1',
  String externalUserId = 'rc-user-1',
  String title = 'Re: your feedback',
}) {
  return {
    'v': 1,
    'id': id,
    'sent_at': 1712345678901,
    'kind': 'alert',
    'origin': 'subject',
    'app_id': 'app-1',
    'external_user_id': externalUserId,
    'title': title,
    'body': 'Fixed in 1.4.2',
  };
}

void main() {
  group('PushService', () {
    late StreamController<Map<String, dynamic>> source;

    setUp(() {
      source = StreamController<Map<String, dynamic>>.broadcast();
    });

    tearDown(() async {
      if (!source.isClosed) await source.close();
    });

    test('parses and emits subject-origin alerts after start', () async {
      final service = PushService(source: source.stream);
      final received = <PushPayload>[];
      service.pushes.listen(received.add);
      service.start();

      source.add(_subjectAlert(externalUserId: 'u-1'));
      source.add(_subjectAlert(externalUserId: 'u-2', title: 'Second'));
      await pumpEventQueue();

      expect(received, hasLength(2));
      final first = received.first as AlertPayload;
      expect(first.origin, PushOrigin.subject);
      expect(first.externalUserId, 'u-1');
      expect((received[1] as AlertPayload).title, 'Second');

      await service.dispose();
    });

    test('parses channel-origin alerts', () async {
      final service = PushService(source: source.stream);
      final received = <PushPayload>[];
      service.pushes.listen(received.add);
      service.start();

      source.add({
        'v': 1,
        'id': '018f0000-0000-7000-8000-0000000000b9',
        'sent_at': 1712345678901,
        'kind': 'alert',
        'channel_slug': 'acme/news',
        'channel_name': 'ACME News',
        'title': 'Hello',
        'body': 'World',
      });
      await pumpEventQueue();

      expect(received, hasLength(1));
      final alert = received.single as AlertPayload;
      expect(alert.origin, PushOrigin.channel);
      expect(alert.channelSlug, 'acme/news');

      await service.dispose();
    });

    test('drops non-conformant payloads instead of emitting', () async {
      final service = PushService(source: source.stream);
      final received = <PushPayload>[];
      service.pushes.listen(received.add);
      service.start();

      source.add({'hello': 'world'}); // no envelope
      source.add(_subjectAlert()); // valid
      await pumpEventQueue();

      expect(received, hasLength(1));
      expect(received.single, isA<AlertPayload>());

      await service.dispose();
    });

    test('does not forward before start', () async {
      final service = PushService(source: source.stream);
      final received = <PushPayload>[];
      service.pushes.listen(received.add);

      source.add(_subjectAlert());
      await pumpEventQueue();
      expect(received, isEmpty);

      service.start();
      source.add(_subjectAlert(externalUserId: 'u-late'));
      await pumpEventQueue();
      expect(received, hasLength(1));
      expect((received.single as AlertPayload).externalUserId, 'u-late');

      await service.dispose();
    });

    test('start is idempotent — one subscription only', () async {
      final service = PushService(source: source.stream);
      final received = <PushPayload>[];
      service.pushes.listen(received.add);
      service.start();
      service.start();

      source.add(_subjectAlert());
      await pumpEventQueue();

      expect(received, hasLength(1));

      await service.dispose();
    });

    test('dispose closes the pushes stream and stops forwarding', () async {
      final service = PushService(source: source.stream);
      var done = false;
      service.pushes.listen((_) {}, onDone: () => done = true);
      service.start();

      await service.dispose();
      await pumpEventQueue();

      expect(done, isTrue);
    });
  });
}
