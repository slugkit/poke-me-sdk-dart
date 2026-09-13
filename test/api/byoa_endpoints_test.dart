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

    test('POSTs external_user_id (no app_id) and returns the subject id',
        () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/devices/me/identify');
        expect(request.headers['authorization'], 'Bearer $deviceToken');
        // app_id is derived server-side from the device — not sent.
        expect(jsonDecode(request.body), {
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
        request: const IdentifyRequest(externalUserId: 'u2'),
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
          request: const IdentifyRequest(externalUserId: 'u'),
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

  group('fetchDevicePushToken', () {
    test('returns the token when present', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/v1/devices/me');
        return http.Response(jsonEncode({'push_token': 'live-tok'}), 200,
            headers: {'content-type': 'application/json'});
      });
      expect(await buildClient(mock).fetchDevicePushToken('dt'), 'live-tok');
    });

    test('returns null when the server has no token (revoked)', () async {
      final mock = MockClient((_) async => http.Response(
            jsonEncode({'push_token': null}),
            200,
            headers: {'content-type': 'application/json'},
          ));
      expect(await buildClient(mock).fetchDevicePushToken('dt'), isNull);
    });
  });

  group('reportReceipts', () {
    test('sends the batch under the device token', () async {
      final mock = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/v1/devices/me/receipts');
        expect(request.headers['authorization'], 'Bearer dt_mine');
        expect(jsonDecode(request.body), {
          'receipts': [
            {
              'notification_id': '019d-a',
              'state': 'opened',
              'at': 1757577243120,
            }
          ],
        });
        return http.Response(
          jsonEncode({'recorded': 1, 'ignored': 0, 'receipts_enabled': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final response = await buildClient(mock).reportReceipts(
        deviceToken: 'dt_mine',
        receipts: [
          Receipt(
            notificationId: '019d-a',
            state: ReceiptState.opened,
            at: DateTime.fromMillisecondsSinceEpoch(1757577243120),
          ),
        ],
      );

      expect(response.recorded, 1);
      expect(response.receiptsEnabled, isTrue);
    });

    test('an older backend that omits receipts_enabled is treated as enabled',
        () async {
      // Absent means enabled: a backend that has never heard of the flag is
      // one where receipts work, and reading absence as "off" would silence
      // the SDK against it for ever.
      final mock = MockClient((_) async => http.Response(
            jsonEncode({'recorded': 1, 'ignored': 0}),
            200,
            headers: {'content-type': 'application/json'},
          ));

      final response = await buildClient(mock).reportReceipts(
        deviceToken: 'dt',
        receipts: [
          Receipt(notificationId: '019d-a', state: ReceiptState.delivered),
        ],
      );
      expect(response.receiptsEnabled, isTrue);
    });
  });
}
