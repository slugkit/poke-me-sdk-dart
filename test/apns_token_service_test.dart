import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pokeme/pokeme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('io.pokeme.pokeme/push_token');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('getToken throws a TIMEOUT PushTokenException when native never replies',
      () async {
    // Native handler that never resolves within the timeout window.
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getToken');
      await Future<void>.delayed(const Duration(seconds: 2));
      return 'tok';
    });

    final service = ApnsTokenService(timeout: const Duration(milliseconds: 50));

    await expectLater(
      service.getToken(),
      throwsA(isA<PushTokenException>()
          .having((e) => e.code, 'code', 'TIMEOUT')
          .having((e) => e.isPermissionDenied, 'isPermissionDenied', isFalse)),
    );
  });

  test('getToken forwards requestPermission to the native call', () async {
    Object? receivedArgs;
    messenger.setMockMethodCallHandler(channel, (call) async {
      receivedArgs = call.arguments;
      return 'apns-tok';
    });

    final result =
        await ApnsTokenService().getToken(requestPermission: false);

    expect(result.token, 'apns-tok');
    expect((receivedArgs as Map)['requestPermission'], isFalse);
  });

  group('detectApnsEnvironment', () {
    void mockEnv(String? value) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getApnsEnvironment');
        return value;
      });
    }

    test('maps sandbox / production / unknown / null', () async {
      final service = ApnsTokenService();

      mockEnv('sandbox');
      expect(await service.detectApnsEnvironment(), ApnsEnvironment.sandbox);

      mockEnv('production');
      expect(await service.detectApnsEnvironment(), ApnsEnvironment.production);

      mockEnv('something-else');
      expect(await service.detectApnsEnvironment(), isNull);

      mockEnv(null);
      expect(await service.detectApnsEnvironment(), isNull);
    });

    test('returns null on a PlatformException (unsupported platform)',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'unimplemented');
      });
      expect(await ApnsTokenService().detectApnsEnvironment(), isNull);
    });
  });
}
