import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pokeme/pokeme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakePushTokenService implements PushTokenService {
  _FakePushTokenService(this.token);

  final String token;

  @override
  Future<PushTokenResult> getToken() async {
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

  IdentityClient buildClient(MockClient mock, {String pushToken = 'apns-abc'}) {
    return IdentityClient(
      tokenService: _FakePushTokenService(pushToken),
      apiClient: PokeApiClient(
        baseUrl: Uri.parse('http://localhost:18080'),
        httpClient: mock,
      ),
      store: store,
      platform: DevicePlatform.macos,
      appId: 'app-uuid',
      clientKey: 'ck_test',
      apnsEnvironment: ApnsEnvironment.sandbox,
    );
  }

  group('registerOnLaunch', () {
    test('registers via the client key and persists the device singletons',
        () async {
      final mock = MockClient((request) async {
        expect(request.url.path, '/api/v1/apps/app-uuid/devices');
        expect(request.headers['x-client-key'], 'ck_test');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['platform'], 'macos');
        expect(body['push_token'], 'apns-abc');
        expect(body.containsKey('device_id'), isFalse);
        return http.Response(
          jsonEncode({'device_id': 'dev-1', 'device_token': 'dt_token'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      await buildClient(mock).registerOnLaunch();

      expect(await store.getDeviceId(), 'dev-1');
      expect(await store.getDeviceToken(), 'dt_token');
    });

    test('refreshes the push token instead of re-registering when known',
        () async {
      await store.setDeviceCredentials(
        deviceId: 'dev-1',
        deviceToken: 'dt_token',
      );

      var hitPath = '';
      final mock = MockClient((request) async {
        hitPath = request.url.path;
        expect(request.method, 'PUT');
        expect(request.headers['authorization'], 'Bearer dt_token');
        expect(jsonDecode(request.body), {
          'platform': 'macos',
          'push_token': 'apns-rotated',
        });
        return http.Response('', 204);
      });

      await buildClient(mock, pushToken: 'apns-rotated').registerOnLaunch();

      expect(hitPath, '/api/v1/devices/me/push-token');
      // Credentials are unchanged.
      expect(await store.getDeviceToken(), 'dt_token');
    });
  });

  group('identify', () {
    test('binds the device and returns the subject id', () async {
      await store.setDeviceCredentials(
        deviceId: 'dev-1',
        deviceToken: 'dt_token',
      );

      final mock = MockClient((request) async {
        expect(request.url.path, '/api/v1/devices/me/identify');
        expect(request.headers['authorization'], 'Bearer dt_token');
        expect(jsonDecode(request.body), {
          'app_id': 'app-uuid',
          'external_user_id': 'rc-user-1',
          'apns_environment': 'sandbox',
        });
        return http.Response(
          jsonEncode({'subject_id': 'subj-1'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final subjectId = await buildClient(mock).identify('rc-user-1');
      expect(subjectId, 'subj-1');
    });

    test('throws StateError when the device is not registered', () async {
      final mock = MockClient((_) async => http.Response('{}', 200));
      await expectLater(
        buildClient(mock).identify('rc-user-1'),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('unidentify', () {
    test('clears the binding when a device token exists', () async {
      await store.setDeviceCredentials(
        deviceId: 'dev-1',
        deviceToken: 'dt_token',
      );

      var called = false;
      final mock = MockClient((request) async {
        called = true;
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/devices/me/unidentify');
        expect(request.headers['authorization'], 'Bearer dt_token');
        return http.Response('{}', 200,
            headers: {'content-type': 'application/json'});
      });

      await buildClient(mock).unidentify();
      expect(called, isTrue);
    });

    test('no-ops when no device token is set', () async {
      var called = false;
      final mock = MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      });

      await buildClient(mock).unidentify();
      expect(called, isFalse);
    });
  });

  group('refreshPushToken', () {
    test('PUTs the new token when a device token exists', () async {
      await store.setDeviceCredentials(
        deviceId: 'dev-1',
        deviceToken: 'dt_token',
      );

      var updated = false;
      final mock = MockClient((request) async {
        updated = true;
        expect(request.method, 'PUT');
        expect(request.url.path, '/api/v1/devices/me/push-token');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['push_token'], 'apns-new');
        return http.Response('', 204);
      });

      await buildClient(mock).refreshPushToken(
        PushTokenResult(type: PushTokenType.apns, token: 'apns-new'),
      );
      expect(updated, isTrue);
    });

    test('no-ops when no device token is set', () async {
      var called = false;
      final mock = MockClient((_) async {
        called = true;
        return http.Response('', 204);
      });

      await buildClient(mock).refreshPushToken(
        PushTokenResult(type: PushTokenType.apns, token: 'apns-new'),
      );
      expect(called, isFalse);
    });
  });
}
