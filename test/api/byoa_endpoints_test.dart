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

  group('registerDevice', () {
    test('POSTs to the app devices path with the client key header', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/apps/app-uuid/devices');
        expect(request.headers['x-client-key'], 'ck_test');
        expect(request.headers['authorization'], isNull);
        expect(jsonDecode(request.body), {
          'platform': 'ios',
          'push_token': 'apns-abc',
        });
        return http.Response(
          jsonEncode({'device_id': 'dev-1', 'device_token': 'dt_token'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final result = await buildClient(mock).registerDevice(
        appId: 'app-uuid',
        clientKey: 'ck_test',
        request: const RegisterDeviceRequest(
          platform: DevicePlatform.ios,
          pushToken: 'apns-abc',
        ),
      );

      expect(result.deviceId, 'dev-1');
      expect(result.deviceToken, 'dt_token');
    });

    test('passes optional device_id when provided', () async {
      final mock = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['device_id'], 'existing-device');
        return http.Response(
          jsonEncode({'device_id': 'existing-device', 'device_token': 'dt_x'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      await buildClient(mock).registerDevice(
        appId: 'app-uuid',
        clientKey: 'ck_test',
        request: const RegisterDeviceRequest(
          platform: DevicePlatform.android,
          pushToken: 'fcm-tok',
          deviceId: 'existing-device',
        ),
      );
    });
  });

  group('identify', () {
    const deviceToken = 'dt_mine';

    test('POSTs app_id + external_user_id and returns the subject id',
        () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/devices/me/identify');
        expect(request.headers['authorization'], 'Bearer $deviceToken');
        expect(jsonDecode(request.body), {
          'app_id': 'app-uuid',
          'external_user_id': 'revenuecat-user-abc123',
        });
        return http.Response(
          jsonEncode({'subject_id': 'subj-1'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final result = await buildClient(mock).identify(
        deviceToken: deviceToken,
        request: const IdentifyRequest(
          appId: 'app-uuid',
          externalUserId: 'revenuecat-user-abc123',
        ),
      );

      expect(result.subjectId, 'subj-1');
    });

    test('includes apns_environment when set', () async {
      final mock = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['apns_environment'], 'sandbox');
        return http.Response(
          jsonEncode({'subject_id': 'subj-2'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      await buildClient(mock).identify(
        deviceToken: deviceToken,
        request: const IdentifyRequest(
          appId: 'app-uuid',
          externalUserId: 'u1',
          apnsEnvironment: ApnsEnvironment.sandbox,
        ),
      );
    });

    test('omits apns_environment when null', () async {
      final mock = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body.containsKey('apns_environment'), isFalse);
        return http.Response(
          jsonEncode({'subject_id': 'subj-3'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      await buildClient(mock).identify(
        deviceToken: deviceToken,
        request: const IdentifyRequest(appId: 'app-uuid', externalUserId: 'u2'),
      );
    });

    test('surfaces a 400 invalid apns_environment as PokeApiException',
        () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({'error': 'invalid apns_environment'}),
          400,
          headers: {'content-type': 'application/json'},
        );
      });

      try {
        await buildClient(mock).identify(
          deviceToken: deviceToken,
          request: const IdentifyRequest(appId: 'a', externalUserId: 'u'),
        );
        fail('expected PokeApiException');
      } on PokeApiException catch (e) {
        expect(e.statusCode, 400);
        expect(e.message, 'invalid apns_environment');
        expect(e.isClientError, isTrue);
      }
    });
  });

  group('unidentify', () {
    const deviceToken = 'dt_mine';

    test('POSTs to the unidentify path with the bearer token and no body',
        () async {
      var called = false;
      final mock = MockClient((request) async {
        called = true;
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/devices/me/unidentify');
        expect(request.headers['authorization'], 'Bearer $deviceToken');
        expect(request.body, isEmpty);
        return http.Response('{}', 200,
            headers: {'content-type': 'application/json'});
      });

      await buildClient(mock).unidentify(deviceToken: deviceToken);
      expect(called, isTrue);
    });
  });
}
