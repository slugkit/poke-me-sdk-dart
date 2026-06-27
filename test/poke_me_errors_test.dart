import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pokeme/pokeme.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeToken implements PushTokenService {
  @override
  Future<PushTokenResult> getToken({bool requestPermission = true}) async =>
      PushTokenResult(type: PushTokenType.apns, token: 'tok');

  @override
  Stream<PushTokenResult> get onTokenRefresh => const Stream.empty();

  @override
  Future<void> openSettings() async {}
}

void main() {
  sqfliteFfiInit();

  Future<PokeMe> build(MockClient mock) => PokeMe.init(
        baseUrl: Uri.parse('http://localhost'),
        appId: 'app-uuid',
        clientKey: 'ck_test',
        platform: DevicePlatform.ios,
        storePath: inMemoryDatabasePath,
        tokenService: _FakeToken(),
        httpClient: mock,
        databaseFactory: databaseFactoryFfi,
        pushSource: const Stream<Map<String, dynamic>>.empty(),
      );

  test('a service error surfaces on errors AND is thrown', () async {
    final mock = MockClient((_) async => http.Response(
          jsonEncode({'error': 'app not found'}),
          404,
          headers: {'content-type': 'application/json'},
        ));
    final poke = await build(mock);

    final errors = <PokeError>[];
    poke.errors.listen(errors.add);

    // Thrown for awaiting callers …
    await expectLater(
      poke.registerOnLaunch(),
      throwsA(isA<PokeApiException>()),
    );
    await pumpEventQueue();

    // … and surfaced on the stream for fire-and-forget callers.
    expect(errors, hasLength(1));
    expect(errors.single.operation, 'registerOnLaunch');
    final apiError = errors.single.error as PokeApiException;
    expect(apiError.statusCode, 404);
    expect(apiError.isClientError, isTrue);

    await poke.close();
  });

  test('a 5xx is surfaced as a server error', () async {
    final mock = MockClient((_) async => http.Response('upstream boom', 503));
    final poke = await build(mock);
    await poke.store.setDeviceCredentials(deviceId: 'd', deviceToken: 'dt');

    final errors = <PokeError>[];
    poke.errors.listen(errors.add);

    await expectLater(
      poke.identify('user-1'),
      throwsA(isA<PokeApiException>()),
    );
    await pumpEventQueue();

    expect(errors.single.operation, 'identify');
    expect((errors.single.error as PokeApiException).isServerError, isTrue);

    await poke.close();
  });

  test('successful operations emit nothing', () async {
    final mock = MockClient((_) async => http.Response(
          jsonEncode({'device_id': 'd', 'device_token': 'dt_x'}),
          200,
          headers: {'content-type': 'application/json'},
        ));
    final poke = await build(mock);

    final errors = <PokeError>[];
    poke.errors.listen(errors.add);

    await poke.registerOnLaunch();
    await pumpEventQueue();

    expect(errors, isEmpty);

    await poke.close();
  });
}
