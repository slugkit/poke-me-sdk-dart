import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pokeme/pokeme.dart';

void main() {
  group('parsePushPayload — alert', () {
    test('parses an APNs-style payload (native types)', () {
      final raw = <String, dynamic>{
        'v': 1,
        'id': '018f0000-0000-7000-8000-000000000001',
        'sent_at': 1712345678901,
        'kind': 'alert',
        'channel_slug': 'acme/alerts',
        'channel_name': 'Production Alerts',
        'priority': 'high',
        'title': 'Deploy finished',
        'body': 'v2.4.1 is live',
        'url': 'https://example.com/release',
        'extras': {'build': 'b-2419', 'count': 3},
      };

      final payload = parsePushPayload(raw);
      expect(payload, isA<AlertPayload>());

      final alert = payload as AlertPayload;
      expect(alert.v, 1);
      expect(alert.id, '018f0000-0000-7000-8000-000000000001');
      expect(alert.sentAt, DateTime.fromMillisecondsSinceEpoch(1712345678901));
      expect(alert.channelSlug, 'acme/alerts');
      expect(alert.channelName, 'Production Alerts');
      expect(alert.priority, MessagePriority.high);
      expect(alert.title, 'Deploy finished');
      expect(alert.body, 'v2.4.1 is live');
      expect(alert.url, 'https://example.com/release');
      expect(alert.extras, equals({'build': 'b-2419', 'count': 3}));
    });

    test('parses an FCM-style payload (all string-coerced)', () {
      final raw = <String, dynamic>{
        'v': '1',
        'id': '018f0000-0000-7000-8000-000000000002',
        'sent_at': '1712345678901',
        'kind': 'alert',
        'channel_slug': 'alerts',
        'channel_name': 'Alerts',
        'priority': 'normal',
        'title': 'Hello',
        'body': 'World',
        'extras': jsonEncode({'k': 'v'}),
      };

      final payload = parsePushPayload(raw);
      expect(payload, isA<AlertPayload>());

      final alert = payload as AlertPayload;
      expect(alert.v, 1);
      expect(alert.sentAt, DateTime.fromMillisecondsSinceEpoch(1712345678901));
      expect(alert.priority, MessagePriority.normal);
      expect(alert.url, isNull);
      expect(alert.extras, equals({'k': 'v'}));
    });

    test('priority defaults to normal when absent', () {
      final raw = <String, dynamic>{
        'v': 1,
        'id': '018f0000-0000-7000-8000-000000000003',
        'sent_at': 1712345678901,
        'kind': 'alert',
        'channel_slug': 'alerts',
        'channel_name': 'Alerts',
        'title': 'Hello',
        'body': 'World',
      };

      final alert = parsePushPayload(raw) as AlertPayload;
      expect(alert.priority, MessagePriority.normal);
    });

    test('optional fields can be absent', () {
      final raw = <String, dynamic>{
        'v': 1,
        'id': '018f0000-0000-7000-8000-000000000004',
        'sent_at': 1712345678901,
        'kind': 'alert',
        'channel_slug': 'alerts',
        'channel_name': 'Alerts',
        'title': 'Hello',
        'body': 'World',
      };

      final alert = parsePushPayload(raw) as AlertPayload;
      expect(alert.url, isNull);
      expect(alert.extras, isNull);
    });
  });

  group('parsePushPayload — origin', () {
    test('defaults to channel origin when absent', () {
      final raw = <String, dynamic>{
        'v': 1,
        'id': '018f0000-0000-7000-8000-0000000000a0',
        'sent_at': 1712345678901,
        'kind': 'alert',
        'channel_slug': 'alerts',
        'channel_name': 'Alerts',
        'title': 'Hi',
        'body': 'there',
      };

      final alert = parsePushPayload(raw) as AlertPayload;
      expect(alert.origin, PushOrigin.channel);
      expect(alert.channelSlug, 'alerts');
      expect(alert.appId, isNull);
      expect(alert.externalUserId, isNull);
    });

    test('parses a subject-origin (BYOA) alert', () {
      final raw = <String, dynamic>{
        'v': 1,
        'id': '018f0000-0000-7000-8000-0000000000a1',
        'sent_at': 1712345678901,
        'kind': 'alert',
        'origin': 'subject',
        'app_id': '018f4a00-0000-7000-8000-000000000001',
        'external_user_id': 'rc-user-42',
        'title': 'Re: your feedback',
        'body': 'Fixed in 1.4.2',
      };

      final alert = parsePushPayload(raw) as AlertPayload;
      expect(alert.origin, PushOrigin.subject);
      expect(alert.appId, '018f4a00-0000-7000-8000-000000000001');
      expect(alert.externalUserId, 'rc-user-42');
      expect(alert.channelSlug, isNull);
      expect(alert.channelName, isNull);
      expect(alert.title, 'Re: your feedback');
      expect(alert.body, 'Fixed in 1.4.2');
      expect(alert.priority, MessagePriority.normal);
    });

    test('subject origin parses with FCM string-coercion', () {
      final raw = <String, dynamic>{
        'v': '1',
        'id': '018f0000-0000-7000-8000-0000000000a2',
        'sent_at': '1712345678901',
        'kind': 'alert',
        'origin': 'subject',
        'app_id': 'app-1',
        'external_user_id': 'u-1',
        'title': 'Hi',
        'body': 'there',
        'extras': jsonEncode({'screen': 'feedback'}),
      };

      final alert = parsePushPayload(raw) as AlertPayload;
      expect(alert.externalUserId, 'u-1');
      expect(alert.extras, equals({'screen': 'feedback'}));
    });

    test('throws on subject origin missing external_user_id', () {
      final raw = <String, dynamic>{
        'v': 1,
        'id': '018f0000-0000-7000-8000-0000000000a3',
        'sent_at': 1712345678901,
        'kind': 'alert',
        'origin': 'subject',
        'app_id': 'app-1',
        'title': 'Hi',
        'body': 'there',
      };
      expect(() => parsePushPayload(raw), throwsFormatException);
    });

    test('throws on an unknown origin value', () {
      final raw = <String, dynamic>{
        'v': 1,
        'id': '018f0000-0000-7000-8000-0000000000a4',
        'sent_at': 1712345678901,
        'kind': 'alert',
        'origin': 'galaxy',
        'title': 'Hi',
        'body': 'there',
      };
      expect(() => parsePushPayload(raw), throwsFormatException);
    });
  });

  group('parsePushPayload — system', () {
    test('parses an APNs-style system payload', () {
      final raw = <String, dynamic>{
        'v': 1,
        'id': '018f0000-0000-7000-8000-000000000005',
        'sent_at': 1712345678901,
        'kind': 'system',
        'channel_slug': 'alerts',
        'event': 'channel_renamed',
        'data': {'new_name': 'Critical Alerts'},
      };

      final payload = parsePushPayload(raw);
      expect(payload, isA<SystemPayload>());

      final system = payload as SystemPayload;
      expect(system.event, 'channel_renamed');
      expect(system.data, equals({'new_name': 'Critical Alerts'}));
    });

    test('parses an FCM-style system payload (data as JSON string)', () {
      final raw = <String, dynamic>{
        'v': '1',
        'id': '018f0000-0000-7000-8000-000000000006',
        'sent_at': '1712345678901',
        'kind': 'system',
        'channel_slug': 'alerts',
        'event': 'channel_slug_changed',
        'data': jsonEncode({'new_slug': 'critical-alerts'}),
      };

      final system = parsePushPayload(raw) as SystemPayload;
      expect(system.event, 'channel_slug_changed');
      expect(system.data, equals({'new_slug': 'critical-alerts'}));
    });

    test('data is optional', () {
      final raw = <String, dynamic>{
        'v': 1,
        'id': '018f0000-0000-7000-8000-000000000007',
        'sent_at': 1712345678901,
        'kind': 'system',
        'channel_slug': 'alerts',
        'event': 'channel_deleted',
      };

      final system = parsePushPayload(raw) as SystemPayload;
      expect(system.data, isNull);
    });
  });

  group('parsePushPayload — errors', () {
    Map<String, dynamic> validAlert() => {
          'v': 1,
          'id': '018f0000-0000-7000-8000-000000000001',
          'sent_at': 1712345678901,
          'kind': 'alert',
          'channel_slug': 'alerts',
          'channel_name': 'Alerts',
          'title': 'Hello',
          'body': 'World',
        };

    test('throws on missing kind', () {
      final raw = validAlert()..remove('kind');
      expect(() => parsePushPayload(raw), throwsFormatException);
    });

    test('throws on invalid kind value', () {
      final raw = validAlert()..['kind'] = 'something_else';
      expect(() => parsePushPayload(raw), throwsFormatException);
    });

    test('throws on missing v', () {
      final raw = validAlert()..remove('v');
      expect(() => parsePushPayload(raw), throwsFormatException);
    });

    test('throws on non-numeric v', () {
      final raw = validAlert()..['v'] = 'not a number';
      expect(() => parsePushPayload(raw), throwsFormatException);
    });

    test('throws on missing id', () {
      final raw = validAlert()..remove('id');
      expect(() => parsePushPayload(raw), throwsFormatException);
    });

    test('throws on missing sent_at', () {
      final raw = validAlert()..remove('sent_at');
      expect(() => parsePushPayload(raw), throwsFormatException);
    });

    test('throws on object sent_at', () {
      final raw = validAlert()..['sent_at'] = {'broken': true};
      expect(() => parsePushPayload(raw), throwsFormatException);
    });

    test('throws on missing channel_slug', () {
      final raw = validAlert()..remove('channel_slug');
      expect(() => parsePushPayload(raw), throwsFormatException);
    });

    test('throws on int channel_slug', () {
      final raw = validAlert()..['channel_slug'] = 42;
      expect(() => parsePushPayload(raw), throwsFormatException);
    });

    test('throws on missing channel_name (alert)', () {
      final raw = validAlert()..remove('channel_name');
      expect(() => parsePushPayload(raw), throwsFormatException);
    });

    test('throws on missing title (alert)', () {
      final raw = validAlert()..remove('title');
      expect(() => parsePushPayload(raw), throwsFormatException);
    });

    test('throws on missing body (alert)', () {
      final raw = validAlert()..remove('body');
      expect(() => parsePushPayload(raw), throwsFormatException);
    });

    test('throws on invalid priority value', () {
      final raw = validAlert()..['priority'] = 'extreme';
      expect(() => parsePushPayload(raw), throwsFormatException);
    });

    test('throws on malformed extras JSON string (FCM-style)', () {
      final raw = validAlert()..['extras'] = '{not json';
      expect(() => parsePushPayload(raw), throwsFormatException);
    });

    test('throws on missing event (system)', () {
      final raw = <String, dynamic>{
        'v': 1,
        'id': '018f0000-0000-7000-8000-000000000001',
        'sent_at': 1712345678901,
        'kind': 'system',
        'channel_slug': 'alerts',
      };
      expect(() => parsePushPayload(raw), throwsFormatException);
    });
  });
}
