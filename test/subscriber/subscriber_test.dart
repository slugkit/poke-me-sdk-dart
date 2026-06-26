import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pokeme/channels.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePushTokenService implements PushTokenService {
  _FakePushTokenService(this.token);

  final String token;

  @override
  Future<PushTokenResult> getToken({bool requestPermission = true}) async {
    return PushTokenResult(type: PushTokenType.apns, token: token);
  }

  @override
  Stream<PushTokenResult> get onTokenRefresh => const Stream.empty();

  @override
  Future<void> openSettings() async {}
}

void main() {
  sqfliteFfiInit();

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

  Subscriber buildSubscriber(MockClient mock, {String pushToken = 'apns-abc'}) {
    return Subscriber(
      tokenService: _FakePushTokenService(pushToken),
      apiClient: PokeApiClient(
        baseUrl: Uri.parse('http://localhost:18080'),
        httpClient: mock,
      ),
      messageStore: store,
      platform: DevicePlatform.macos,
    );
  }

  group('subscribeByJoinKey', () {
    test('persists channel and device singletons on success', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/subscribe/by-key');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['join_key'], 'jk_abc');
        expect(body['platform'], 'macos');
        expect(body['push_token'], 'apns-abc');
        expect(body.containsKey('device_id'), isFalse);
        return http.Response(
          jsonEncode({
            'device_id': 'dev-1',
            'subscription_id': 'sub-1',
            'device_token': 'dt-token',
            'channel': {'slug': 'acme/news', 'name': 'ACME News'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final subscriber = buildSubscriber(mock);
      final channel = await subscriber.subscribeByJoinKey('jk_abc');

      expect(channel.slug, 'acme/news');
      expect(channel.name, 'ACME News');
      expect(channel.subscriptionId, 'sub-1');

      expect(await store.getDeviceId(), 'dev-1');
      expect(await store.getDeviceToken(), 'dt-token');

      final stored = await store.getChannel('acme/news');
      expect(stored, isNotNull);
      expect(stored!.subscriptionId, 'sub-1');
    });

    test('reuses existing device_id on subsequent subscribes', () async {
      await store.setDeviceCredentials(
        deviceId: 'dev-existing',
        deviceToken: 'dt-old',
      );

      final mock = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['device_id'], 'dev-existing');
        return http.Response(
          jsonEncode({
            'device_id': 'dev-existing',
            'subscription_id': 'sub-2',
            'device_token': 'dt-new',
            'channel': {'slug': 'b', 'name': 'B'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      await buildSubscriber(mock).subscribeByJoinKey('jk_2');

      expect(await store.getDeviceToken(), 'dt-new');
    });

    test('does not write singletons or channel on API error', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({'title': 'Invalid join key'}),
          404,
          headers: {'content-type': 'application/problem+json'},
        );
      });

      final subscriber = buildSubscriber(mock);

      await expectLater(
        subscriber.subscribeByJoinKey('jk_bad'),
        throwsA(isA<PokeApiException>()),
      );

      expect(await store.getDeviceId(), isNull);
      expect(await store.listChannels(), isEmpty);
    });
  });

  group('subscribeByRoutingKey', () {
    test('hits the routing-key endpoint and persists', () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/api/v1/subscribe/acme/news');
        return http.Response(
          jsonEncode({
            'device_id': 'dev-1',
            'subscription_id': 'sub-1',
            'device_token': 'dt-token',
            'channel': {'slug': 'acme/news', 'name': 'ACME News'},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final channel =
          await buildSubscriber(mock).subscribeByRoutingKey('acme/news');

      expect(channel.slug, 'acme/news');
      expect(await store.getDeviceToken(), 'dt-token');
    });
  });

  group('unsubscribe', () {
    test('calls DELETE with the channel subscription_id and revokes locally',
        () async {
      await store.setDeviceCredentials(
        deviceId: 'dev-1',
        deviceToken: 'dt-token',
      );
      await store.joinChannel(Channel(
        slug: 'acme/news',
        name: 'ACME News',
        joinedAt: DateTime(2026, 1, 1),
        subscriptionId: 'sub-42',
      ));

      var deleted = false;
      final mock = MockClient((request) async {
        expect(request.method, 'DELETE');
        expect(request.url.path,
            '/api/v1/devices/me/subscriptions/sub-42');
        expect(request.headers['authorization'], 'Bearer dt-token');
        deleted = true;
        return http.Response('', 204);
      });

      await buildSubscriber(mock).unsubscribe('acme/news');
      expect(deleted, isTrue);

      // Locally the channel is now in revoked state and messages purged.
      final channel = await store.getChannel('acme/news');
      expect(channel, isNotNull);
      expect(channel!.state, ChannelState.revoked);
    });

    test('throws when no device token is set', () async {
      final mock = MockClient((_) async => http.Response('', 204));
      await expectLater(
        buildSubscriber(mock).unsubscribe('acme/news'),
        throwsA(isA<StateError>()),
      );
    });

    test('throws when channel is unknown', () async {
      await store.setDeviceCredentials(
        deviceId: 'dev-1',
        deviceToken: 'dt-token',
      );
      final mock = MockClient((_) async => http.Response('', 204));
      await expectLater(
        buildSubscriber(mock).unsubscribe('nope'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('refreshPushToken', () {
    test('PUTs to update endpoint when device token exists', () async {
      await store.setDeviceCredentials(
        deviceId: 'dev-1',
        deviceToken: 'dt-token',
      );

      var updated = false;
      final mock = MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.url.path, '/api/v1/devices/me/push-token');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['platform'], 'macos');
        expect(body['push_token'], 'new-apns');
        updated = true;
        return http.Response('', 204);
      });

      await buildSubscriber(mock).refreshPushToken(
        PushTokenResult(type: PushTokenType.apns, token: 'new-apns'),
      );
      expect(updated, isTrue);
    });

    test('no-ops when device token is missing', () async {
      var called = false;
      final mock = MockClient((_) async {
        called = true;
        return http.Response('', 204);
      });

      await buildSubscriber(mock).refreshPushToken(
        PushTokenResult(type: PushTokenType.apns, token: 'new-apns'),
      );
      expect(called, isFalse);
    });
  });
}
