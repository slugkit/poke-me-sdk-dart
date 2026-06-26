import 'package:flutter_test/flutter_test.dart';
import 'package:pokeme/pokeme.dart';

void main() {
  group('PushTokenType', () {
    test('has apns and fcm values', () {
      expect(PushTokenType.values, containsAll([PushTokenType.apns, PushTokenType.fcm]));
    });
  });

  group('PushTokenResult', () {
    test('stores type and token', () {
      final result = PushTokenResult(
        type: PushTokenType.apns,
        token: 'abc123',
      );
      expect(result.type, PushTokenType.apns);
      expect(result.token, 'abc123');
    });

    test('toString includes type and token', () {
      final result = PushTokenResult(
        type: PushTokenType.fcm,
        token: 'xyz789',
      );
      expect(result.toString(), contains('FCM'));
      expect(result.toString(), contains('xyz789'));
    });
  });

  group('PushTokenException', () {
    test('stores message', () {
      final exception = PushTokenException('test error');
      expect(exception.message, 'test error');
    });

    test('toString includes message', () {
      final exception = PushTokenException('permission denied');
      expect(exception.toString(), contains('permission denied'));
    });
  });
}
