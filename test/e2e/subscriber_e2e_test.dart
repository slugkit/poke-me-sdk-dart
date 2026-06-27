@Tags(['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pokeme/channels.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// End-to-end tests that exercise the SDK against the real backend
/// running in the local docker compose omnibus.
///
/// These tests are tagged `e2e` and skipped by default. The Make
/// target `app-test-e2e` is responsible for:
///
/// 1. Verifying the omnibus is healthy on `localhost:18080`
/// 2. Minting a fresh join key via `scripts/lib/e2e_helpers.sh::mint_join_key`
/// 3. Invoking `flutter test --tags e2e` with the join key passed in
///    via `--dart-define=POKEME_E2E_JOIN_KEY=...` and the base URL
///    via `--dart-define=POKEME_E2E_BASE_URL=...`
///
/// Running this file directly without those defines yields a single
/// "skipped" test with a message explaining what's missing.

const _baseUrlOverride = String.fromEnvironment(
  'POKEME_E2E_BASE_URL',
  defaultValue: 'http://localhost:18080',
);

const _joinKey = String.fromEnvironment(
  'POKEME_E2E_JOIN_KEY',
  defaultValue: '',
);

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

  @override
  Future<ApnsEnvironment?> detectApnsEnvironment() async => null;
}

void main() {
  sqfliteFfiInit();

  final skipReason = _joinKey.isEmpty
      ? 'POKEME_E2E_JOIN_KEY not set — run via `make app-test-e2e` '
          'or pass --dart-define=POKEME_E2E_JOIN_KEY=...'
      : null;

  group('Subscriber e2e against omnibus', () {
    late MessageStore store;
    late PokeApiClient api;
    late Subscriber subscriber;
    final List<String> subscriptionsToClean = [];
    String? deviceTokenForCleanup;

    setUp(() async {
      store = await MessageStore.open(
        path: inMemoryDatabasePath,
        databaseFactory: databaseFactoryFfi,
      );
      api = PokeApiClient(baseUrl: Uri.parse(_baseUrlOverride));
      subscriber = Subscriber(
        tokenService: _FakePushTokenService(
          'e2e-fake-push-token-${DateTime.now().millisecondsSinceEpoch}',
        ),
        apiClient: api,
        messageStore: store,
        platform: DevicePlatform.macos,
      );
      subscriptionsToClean.clear();
      deviceTokenForCleanup = null;
    });

    tearDown(() async {
      // Per-subscription cleanup: DELETE /devices/me/subscriptions/{id}
      // is the only working teardown path right now —
      // DELETE /devices/me is not yet implemented (see
      // slugkit/poke-me#48), so the device row leaks. Subscriptions are
      // the bigger leak risk because they multiply per test run.
      if (deviceTokenForCleanup != null) {
        for (final subId in subscriptionsToClean) {
          try {
            await api.unsubscribe(
              deviceToken: deviceTokenForCleanup!,
              subscriptionRef: subId,
            );
          } catch (e) {
            // ignore: avoid_print
            print('e2e teardown: unsubscribe $subId failed: $e');
          }
        }
      }
      api.close();
      await store.close();
    });

    test('full subscribe → verify via getDevice → unsubscribe', () async {
      // 1. Subscribe with the freshly minted join key.
      final channel = await subscriber.subscribeByJoinKey(_joinKey);
      expect(channel.slug, isNotEmpty);
      expect(channel.subscriptionId, isNotEmpty);

      subscriptionsToClean.add(channel.subscriptionId);

      final deviceToken = await store.getDeviceToken();
      expect(deviceToken, isNotNull);
      deviceTokenForCleanup = deviceToken;

      final deviceId = await store.getDeviceId();
      expect(deviceId, isNotNull);

      // 2. The channel should now be in the local store with the
      // subscription_id we got back from the subscribe call.
      final stored = await store.getChannel(channel.slug);
      expect(stored, isNotNull);
      expect(stored!.subscriptionId, channel.subscriptionId);

      // 3. The device endpoint should report the same device + the
      // new subscription. We use GET /devices/me here because the
      // dedicated /devices/me/channels endpoint isn't implemented yet
      // (slugkit/poke-me#48).
      final device = await api.getDevice(deviceToken!);
      expect(device.id, deviceId);
      expect(
        device.subscriptions.map((s) => s.id),
        contains(channel.subscriptionId),
        reason: 'subscription should appear under /api/v1/devices/me',
      );
      expect(
        device.subscriptions
            .firstWhere((s) => s.id == channel.subscriptionId)
            .channelSlug,
        channel.slug,
      );

      // 4. Unsubscribe and verify the local channel transitions to
      // revoked. Subscriber.unsubscribe both calls the API and
      // updates the local state in one go.
      await subscriber.unsubscribe(channel.slug);
      final afterUnsub = await store.getChannel(channel.slug);
      expect(afterUnsub, isNotNull);
      expect(afterUnsub!.state, ChannelState.revoked);

      // After unsubscribe, the subscription is gone server-side too,
      // so don't try to clean it up again in tearDown.
      subscriptionsToClean.remove(channel.subscriptionId);
    }, skip: skipReason);

    test('subscribeByJoinKey rejects an invalid key', () async {
      await expectLater(
        subscriber.subscribeByJoinKey('jk_definitely_not_valid_xxxxxxxx'),
        throwsA(isA<PokeApiException>().having(
          (e) => e.statusCode,
          'statusCode',
          isIn([400, 401, 404]),
        )),
      );
    }, skip: skipReason);
  });
}
