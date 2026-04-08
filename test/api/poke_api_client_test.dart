import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pokeme/pokeme.dart';

void main() {
  final baseUrl = Uri.parse('http://localhost:18080');

  PokeApiClient buildClient(MockClient mock) {
    return PokeApiClient(baseUrl: baseUrl, httpClient: mock);
  }

  group('subscribeByJoinKey', () {
    test('round-trips a successful subscribe', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/subscribe/by-key');
        expect(request.headers['content-type'], 'application/json');
        expect(jsonDecode(request.body), {
          'join_key': 'jk-secret',
          'platform': 'macos',
          'push_token': 'apns-abc',
        });
        return http.Response(
          jsonEncode({
            'device_id': 'dev-1',
            'subscription_id': 'sub-1',
            'device_token': 'dt-token',
            'channel': {
              'slug': 'acme/news',
              'name': 'ACME News',
              'routing_key': 'acme/news',
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = buildClient(mock);
      final result = await client.subscribeByJoinKey(
        const SubscribeByKeyRequest(
          joinKey: 'jk-secret',
          platform: DevicePlatform.macos,
          pushToken: 'apns-abc',
        ),
      );

      expect(result.deviceId, 'dev-1');
      expect(result.subscriptionId, 'sub-1');
      expect(result.deviceToken, 'dt-token');
      expect(result.channel.slug, 'acme/news');
      expect(result.channel.name, 'ACME News');
      expect(result.channel.routingKey, 'acme/news');
    });

    test('passes optional device_id when provided', () async {
      final mock = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['device_id'], 'existing-device');
        return http.Response(
          jsonEncode({
            'device_id': 'existing-device',
            'subscription_id': 'sub-2',
            'device_token': 'dt-token',
            'channel': {'slug': 'a', 'name': 'A'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      await buildClient(mock).subscribeByJoinKey(
        const SubscribeByKeyRequest(
          joinKey: 'jk-foo',
          platform: DevicePlatform.ios,
          pushToken: 'tok',
          deviceId: 'existing-device',
        ),
      );
    });

    test('decodes problem+json error responses', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'type': 'https://docs.poke-me.io/errors/invalid_join_key',
            'title': 'Invalid join key',
            'status': 401,
            'detail': 'The join key has been revoked.',
          }),
          401,
          headers: {'content-type': 'application/problem+json'},
        );
      });

      try {
        await buildClient(mock).subscribeByJoinKey(
          const SubscribeByKeyRequest(
            joinKey: 'jk-revoked',
            platform: DevicePlatform.android,
            pushToken: 'tok',
          ),
        );
        fail('expected PokeApiException');
      } on PokeApiException catch (e) {
        expect(e.statusCode, 401);
        expect(e.problemType,
            'https://docs.poke-me.io/errors/invalid_join_key');
        expect(e.title, 'Invalid join key');
        expect(e.detail, 'The join key has been revoked.');
        expect(e.isClientError, isTrue);
        expect(e.isTransportError, isFalse);
      }
    });

    test('falls back to status-only error when body is not problem+json',
        () async {
      final mock = MockClient((request) async {
        return http.Response('upstream timeout', 504);
      });

      try {
        await buildClient(mock).subscribeByJoinKey(
          const SubscribeByKeyRequest(
            joinKey: 'jk-x',
            platform: DevicePlatform.web,
            pushToken: 'tok',
          ),
        );
        fail('expected PokeApiException');
      } on PokeApiException catch (e) {
        expect(e.statusCode, 504);
        expect(e.detail, 'upstream timeout');
        expect(e.isServerError, isTrue);
      }
    });

    // The current backend returns userver-default `{"code","message"}`
    // instead of RFC 7807 problem+json — see TODO in API.md.
    // Verify the client lifts the human-readable bit out anyway.
    test('extracts message from userver default error envelope', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'code': '401',
            'message': '{"error":"invalid join key"}',
          }),
          401,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });

      try {
        await buildClient(mock).subscribeByJoinKey(
          const SubscribeByKeyRequest(
            joinKey: 'jk-bogus',
            platform: DevicePlatform.macos,
            pushToken: 'tok',
          ),
        );
        fail('expected PokeApiException');
      } on PokeApiException catch (e) {
        expect(e.statusCode, 401);
        expect(e.message, 'invalid join key');
        expect(e.detail, 'invalid join key');
      }
    });

    test('extracts error from nginx auth_request envelope', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({'error': 'unauthorized'}),
          401,
          headers: {'content-type': 'application/json'},
        );
      });

      try {
        await buildClient(mock).listDeviceChannels('bad-token');
        fail('expected PokeApiException');
      } on PokeApiException catch (e) {
        expect(e.statusCode, 401);
        expect(e.message, 'unauthorized');
      }
    });
  });

  group('subscribeByRoutingKey', () {
    test('hits the routing-key path', () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/api/v1/subscribe/acme/news');
        return http.Response(
          jsonEncode({
            'device_id': 'd',
            'subscription_id': 's',
            'device_token': 'dt',
            'channel': {'slug': 'acme/news', 'name': 'ACME News'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      await buildClient(mock).subscribeByRoutingKey(
        routingKey: 'acme/news',
        request: const SubscribeByRoutingKeyRequest(
          platform: DevicePlatform.ios,
          pushToken: 'tok',
        ),
      );
    });
  });

  group('device-authenticated endpoints', () {
    const deviceToken = 'dt-mine';

    test('listDeviceChannels parses items', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/v1/devices/me/channels');
        expect(request.headers['authorization'], 'Bearer $deviceToken');
        return http.Response(
          jsonEncode({
            'items': [
              {
                'subscription_id': 'sub-1',
                'slug': 'acme/news',
                'name': 'ACME News',
                'joined_at': '2026-01-01T00:00:00Z',
              },
              {
                'subscription_id': 'sub-2',
                'slug': 'alerts',
                'name': 'Alerts',
                'joined_at': '2026-02-01T00:00:00Z',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final channels = await buildClient(mock).listDeviceChannels(deviceToken);
      expect(channels, hasLength(2));
      expect(channels.first.slug, 'acme/news');
      expect(channels.last.subscriptionId, 'sub-2');
    });

    test('getEventsSince includes the cursor in the query', () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/api/v1/devices/me/events');
        expect(request.url.query, 'since=018f-cursor');
        return http.Response(
          jsonEncode({'items': []}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      await buildClient(mock).getEventsSince(
        deviceToken: deviceToken,
        sinceMessageId: '018f-cursor',
      );
    });

    test('getEventsSince omits the cursor when null', () async {
      final mock = MockClient((request) async {
        expect(request.url.query, '');
        return http.Response(
          jsonEncode({'items': []}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      await buildClient(mock).getEventsSince(deviceToken: deviceToken);
    });

    test('getChannelHistory targets the right path', () async {
      final mock = MockClient((request) async {
        expect(
          request.url.path,
          '/api/v1/devices/me/channels/acme/news/history',
        );
        return http.Response(
          jsonEncode({
            'items': [
              {
                'slug': 'acme/news',
                'name': 'ACME News',
                'changed_at': '2026-03-01T00:00:00Z',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final history = await buildClient(mock).getChannelHistory(
        deviceToken: deviceToken,
        slug: 'acme/news',
      );
      expect(history, hasLength(1));
    });

    test('updatePushToken sends the new token', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path, '/api/v1/devices/me/push-token');
        expect(jsonDecode(request.body), {
          'platform': 'macos',
          'push_token': 'new-token',
        });
        return http.Response('', 204);
      });

      await buildClient(mock).updatePushToken(
        deviceToken: deviceToken,
        request: const UpdatePushTokenRequest(
          platform: DevicePlatform.macos,
          pushToken: 'new-token',
        ),
      );
    });

    test('unsubscribe DELETEs the subscription', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'DELETE');
        expect(request.url.path, '/api/v1/devices/me/subscriptions/sub-1');
        return http.Response('', 204);
      });

      await buildClient(mock).unsubscribe(
        deviceToken: deviceToken,
        subscriptionRef: 'sub-1',
      );
    });

    test('deleteDevice DELETEs the device root', () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/api/v1/devices/me');
        return http.Response('', 204);
      });

      await buildClient(mock).deleteDevice(deviceToken);
    });
  });

  group('transport errors', () {
    test('wraps exceptions thrown from the underlying client', () async {
      final mock = MockClient((request) async {
        throw const FormatException('boom');
      });

      try {
        await buildClient(mock).subscribeByJoinKey(
          const SubscribeByKeyRequest(
            joinKey: 'jk-x',
            platform: DevicePlatform.ios,
            pushToken: 'tok',
          ),
        );
        fail('expected PokeApiException');
      } on PokeApiException catch (e) {
        expect(e.isTransportError, isTrue);
        expect(e.statusCode, isNull);
        expect(e.message, contains('boom'));
      }
    });
  });
}
