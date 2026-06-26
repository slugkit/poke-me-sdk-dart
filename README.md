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
