# pokeme

Flutter client SDK for **poke-me** — push notifications addressed to your own
app's users by an opaque external id (bring-your-own-app), or to poke-me
channels.

It owns the platform push plumbing for you: requesting the APNs/FCM token,
receiving incoming pushes natively (no `firebase_messaging` dependency), and a
small typed API over the poke-me HTTP endpoints.

- **iOS / macOS** — native APNs.
- **Android** — FCM (the only Firebase touch-point; you supply your own
  `google-services.json`).

## Install

Add the SDK as a git dependency, pinned to a tag:

```yaml
dependencies:
  pokeme:
    git:
      url: https://github.com/slugkit/poke-me-sdk-dart.git
      ref: v0.1.0
```

Then complete the per-platform push setup (Firebase project, APNs key,
entitlements) — see **[SETUP.md](SETUP.md)**.

## Quick start (BYOA)

A bring-your-own-app integration registers an anonymous install, binds it to
your end-user, and listens for pushes:

```dart
import 'package:pokeme/pokeme.dart';

final poke = await PokeMe.init(
  baseUrl: Uri.parse('https://your-poke-me-host'),
  appId: 'your-app-uuid',          // from your poke-me app
  clientKey: 'ck_…',               // publishable, shipped in the binary
  platform: DevicePlatform.ios,    // host supplies its platform
  storePath: dbPath,               // a writable file path
);

await poke.registerOnLaunch();     // anonymous install → device token persisted
await poke.identify(userId);       // bind to your opaque end-user id

poke.pushes.listen((push) {
  if (push is AlertPayload) {
    // push.title / push.body / push.externalUserId — show or route
  }
});

// on logout:
await poke.unidentify();
```

`registerOnLaunch()` is idempotent — call it on every launch; it reuses the
stored device and just refreshes the push token. `identify()` is safe to call
on every resolved login.

The publish side (sending a notification to a user) is a server-to-server call
made from **your** backend with a secret key; it is not part of this SDK.

### Deferring the permission prompt

By default `registerOnLaunch()` requests notification permission, which shows
the OS prompt on Apple platforms. To follow the Apple HIG and defer that prompt
to a contextual moment, pass `requestPermission: false` at launch and request
it later:

```dart
// At launch — register if already permitted; never shows a prompt:
await poke.registerOnLaunch(requestPermission: false);

// Later, at a contextual moment (e.g. the user opted into replies):
await poke.registerOnLaunch();   // requests permission, shows the prompt
await poke.identify(userId);
```

When deferred and permission hasn't been granted yet, `registerOnLaunch` is a
no-op — the device stays unregistered until the contextual call. (On Android
fetching the token never prompts, so the flag has no effect there; requesting
`POST_NOTIFICATIONS` on Android 13+ is the host app's responsibility.)

### Error handling

Every operation throws a rich `PokeApiException` on failure (`statusCode`,
`isClientError`, `isServerError`, `isTransportError`, `detail`). Errors are also
**logged** via `dart:developer` under the `pokeme` name, and **surfaced on a
stream** so fire-and-forget calls don't vanish:

```dart
poke.errors.listen((e) {
  // e.operation: 'registerOnLaunch' | 'identify' | …
  // e.error: PokeApiException(statusCode: 404, …)
  reportToTelemetry(e.error);
});

// still throws for awaiting callers:
try {
  await poke.identify(userId);
} on PokeApiException catch (e) {
  if (e.isServerError) scheduleRetry();
}
```

Set `pokemeLoggingEnabled = false` to silence the SDK's `dart:developer` output.

### APNs environment (read this on Apple)

Leave `apnsEnvironment` **null** and the SDK auto-detects it from the embedded
provisioning profile (the signing entitlement) on Apple platforms. Pass it
explicitly only to override.

It must match the **signing entitlement**, not the Dart build mode. Do **not**
gate it on `kReleaseMode`: a `flutter run --release` to a development-signed
device receives a **sandbox** token even though `kReleaseMode == true`. Passing
`production` there makes every push fail with `BadDeviceToken`, after which the
server cascade-revokes the device and pushes stop silently.

### Recovery & diagnostics

`registerOnLaunch` returns a `RegistrationStatus` (`registered` / `refreshed` /
`permissionDeferred`). If the server cascade-revokes a device (e.g. after the
mistake above), recover by polling:

```dart
final status = await poke.ensureRegistered(); // re-registers if the server lost the token
```

Diagnostic getters: `poke.currentPushToken`, `await poke.deviceToken`,
`await poke.deviceId`.

### Android notifications

On Android the SDK posts the system notification itself (the backend sends
data-only FCM, which Android never auto-displays — unlike APNs alerts on
iOS/macOS). It creates a notification channel, and a tap relaunches the app with
the payload as `pokeme_*` intent extras. Pass `androidAutoDisplay: false` to
`PokeMe.init` if your app renders its own notifications from `pushes`. The
plugin declares and requests `POST_NOTIFICATIONS` (Android 13+) during
`registerOnLaunch`.

## Two import surfaces

```dart
import 'package:pokeme/pokeme.dart';    // core: register · identify · receive
import 'package:pokeme/channels.dart';  // optional: poke-me channel subscribe
```

Most apps need only the core barrel. The `channels` barrel adds the
join-key / routing-key subscription surface (`Subscriber`, `Channel`, …) and
re-exports the core.

## Platforms

| Platform | Push transport | Token |
|---|---|---|
| iOS      | APNs           | hex device token |
| macOS    | APNs           | hex device token |
| Android  | FCM            | FCM token (requires `google-services.json`) |

## Licence

Apache 2.0 — see [LICENSE](LICENSE).
