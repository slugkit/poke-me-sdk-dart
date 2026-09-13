import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pokeme/pokeme.dart';

/// Receipts are the only way anyone learns what became of a notification, and
/// they arrive at fan-out volume on the end-user's battery. Every test here is
/// about one of the two halves of that: reporting what actually happened, and
/// not being expensive about it.
void main() {
  final baseUrl = Uri.parse('http://localhost:18080');

  /// A mock that records each batch it was sent and answers [body].
  ({MockClient client, List<List<Map<String, dynamic>>> batches}) recorder({
    Map<String, dynamic> body = const {
      'recorded': 1,
      'ignored': 0,
      'receipts_enabled': true,
    },
    int failTimes = 0,
  }) {
    final batches = <List<Map<String, dynamic>>>[];
    var failures = 0;
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/api/v1/devices/me/receipts');
      expect(request.headers['authorization'], 'Bearer dt_token');
      final decoded = jsonDecode(request.body) as Map<String, dynamic>;
      final receipts = (decoded['receipts'] as List)
          .cast<Map<String, dynamic>>();
      batches.add(receipts);
      if (failures < failTimes) {
        failures++;
        return http.Response('{"error":"nope"}', 500);
      }
      return http.Response(jsonEncode(body), 200,
          headers: {'content-type': 'application/json'});
    });
    return (client: client, batches: batches);
  }

  ReceiptReporter build(
    MockClient client, {
    String? token = 'dt_token',
    Duration debounce = Duration.zero,
    int maxBuffered = 512,
  }) =>
      ReceiptReporter(
        api: PokeApiClient(baseUrl: baseUrl, httpClient: client),
        deviceToken: () async => token,
        debounce: debounce,
        maxBuffered: maxBuffered,
      );

  group('reporting', () {
    test('sends what was observed, with the device token and a clock',
        () async {
      final r = recorder();
      final reporter = build(r.client);

      reporter.report('019d-a', ReceiptState.delivered);
      reporter.report('019d-a', ReceiptState.opened);
      await reporter.flush();

      expect(r.batches, hasLength(1));
      final batch = r.batches.single;
      expect(batch.map((e) => e['notification_id']), ['019d-a', '019d-a']);
      expect(batch.map((e) => e['state']), ['delivered', 'opened']);
      // Milliseconds since the epoch — the same unit the push envelope uses,
      // and the one every platform produces without a formatter.
      expect(batch.first['at'], isA<int>());
      expect(batch.first['at'], greaterThan(1700000000000));
    });

    test('the three states are independent — shown alone is legal', () async {
      final r = recorder();
      final reporter = build(r.client);

      reporter.report('019d-a', ReceiptState.shown);
      await reporter.flush();

      expect(r.batches.single.single['state'], 'shown');
    });

    test('one burst becomes one request', () async {
      // The property the debounce exists for: an app resuming with a dozen
      // buffered notifications must not make a dozen requests.
      final r = recorder();
      final reporter = build(r.client);

      for (var i = 0; i < 12; i++) {
        reporter.report('019d-$i', ReceiptState.delivered);
      }
      await reporter.flush();

      expect(r.batches, hasLength(1));
      expect(r.batches.single, hasLength(12));
    });

    test('a batch larger than the cap is split, not truncated', () async {
      // The backend refuses more than 64 rather than truncating, so a client
      // that sends 70 and assumes success has silently lost six.
      final r = recorder();
      final reporter = build(r.client);

      for (var i = 0; i < 70; i++) {
        reporter.report('019d-$i', ReceiptState.delivered);
      }
      await reporter.flush();

      expect(r.batches.map((b) => b.length), [64, 6]);
    });

    test('the same observation twice is buffered once', () async {
      final r = recorder();
      final reporter = build(r.client);

      reporter.report('019d-a', ReceiptState.delivered);
      reporter.report('019d-a', ReceiptState.delivered);
      await reporter.flush();

      expect(r.batches.single, hasLength(1));
    });

    test('flushing an empty buffer makes no request', () async {
      final r = recorder();
      await build(r.client).flush();
      expect(r.batches, isEmpty);
    });

    test('the debounce sends without an explicit flush', () async {
      final r = recorder();
      final reporter = build(r.client, debounce: const Duration(milliseconds: 20));

      reporter.report('019d-a', ReceiptState.delivered);
      expect(r.batches, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(r.batches, hasLength(1));
    });
  });

  group('not being expensive', () {
    test('a failure is retried exactly once, then dropped', () async {
      // Idempotent per (notification, state), so the retry cannot double-count
      // — and a receipt is not worth a durable queue, so the second failure is
      // the end of it.
      final r = recorder(failTimes: 1);
      final reporter = build(r.client);

      reporter.report('019d-a', ReceiptState.delivered);
      await reporter.flush();
      expect(r.batches, hasLength(2), reason: 'should retry once');
      expect(reporter.pending, 0);

      final dead = recorder(failTimes: 99);
      final givingUp = build(dead.client);
      givingUp.report('019d-b', ReceiptState.delivered);
      await givingUp.flush();
      expect(dead.batches, hasLength(2), reason: 'should not retry twice');
      expect(givingUp.pending, 0, reason: 'a dropped receipt is dropped');
    });

    test('receipts_enabled: false stops reporting for the process', () async {
      // A business condition, not a transient one. A fleet of devices retrying
      // a billing decision is the failure this flag exists to prevent.
      final r = recorder(body: const {
        'recorded': 0,
        'ignored': 1,
        'receipts_enabled': false,
      });
      final reporter = build(r.client);

      reporter.report('019d-a', ReceiptState.delivered);
      await reporter.flush();
      expect(r.batches, hasLength(1));
      expect(reporter.disabled, isTrue);

      reporter.report('019d-b', ReceiptState.opened);
      await reporter.flush();
      expect(r.batches, hasLength(1), reason: 'kept reporting after being told not to');
      expect(reporter.pending, 0);
    });

    test('nothing is reported before the device has a token', () async {
      // A receipt is addressed by the device token. Without one there is
      // nothing to report *as*, and holding the buffer would hold it for ever.
      final r = recorder();
      final reporter = build(r.client, token: null);

      reporter.report('019d-a', ReceiptState.delivered);
      await reporter.flush();

      expect(r.batches, isEmpty);
      expect(reporter.pending, 0);
    });

    test('the buffer is bounded, dropping the oldest', () async {
      final r = recorder();
      final reporter = build(r.client, maxBuffered: 3);

      for (var i = 0; i < 5; i++) {
        reporter.report('019d-$i', ReceiptState.delivered);
      }
      await reporter.flush();

      expect(r.batches.single.map((e) => e['notification_id']),
          ['019d-2', '019d-3', '019d-4']);
    });

    test('an empty notification id is ignored', () async {
      final r = recorder();
      final reporter = build(r.client);
      reporter.report('', ReceiptState.delivered);
      await reporter.flush();
      expect(r.batches, isEmpty);
    });

    test('concurrent flushes do not send a receipt twice', () async {
      final r = recorder();
      final reporter = build(r.client);

      reporter.report('019d-a', ReceiptState.delivered);
      await Future.wait([reporter.flush(), reporter.flush()]);

      expect(r.batches, hasLength(1));
    });

    test('close makes a last attempt and then stops accepting', () async {
      final r = recorder();
      final reporter = build(r.client);

      reporter.report('019d-a', ReceiptState.delivered);
      await reporter.close();
      expect(r.batches, hasLength(1));

      reporter.report('019d-b', ReceiptState.delivered);
      expect(reporter.pending, 0);
    });
  });
}
