## 0.5.1

* **iOS: foreground pushes now present a banner** (#10). The plugin installs
  itself as the `UNUserNotificationCenter` delegate (chained, so it doesn't
  clobber other plugins like flutter_local_notifications) and implements
  `willPresent`, also forwarding the payload to Dart. Previously iOS silently
  suppressed the banner — and didn't deliver the payload — while the app was
  foregrounded. (macOS already did this.) ⚠️ native — verify on a device.

## 0.5.0

BYOA recoverability + observability (from the field report, poke-me-sdk-dart#8):

* **`registerOnLaunch` returns a `RegistrationStatus`** (`registered` /
  `refreshed` / `permissionDeferred`) instead of `void`, so callers can tell
  "registered with the server" from "did nothing because permission was
  deferred". **Breaking** for callers that relied on the `Future<void>` type.
* **`ensureRegistered()`** — recovers from a server-side cascade-revoke: polls
  `GET /devices/me` and re-registers if the server has lost this device's push
  token (or the device row is gone). Returns `alreadyCurrent` when healthy.
* **`identify` sends `apns_environment` only when it changes** (not on every
  call), so a corrected value isn't clobbered on each identify. Added an
  optional per-call `apnsEnvironment` override.
* **Diagnostic accessors** on `PokeMe`: `currentPushToken`, `deviceToken`,
  `deviceId`.
* **`apnsEnvironment` auto-detection** — when omitted from `PokeMe.init`, the
  SDK reads `aps-environment` from the embedded provisioning profile on Apple
  platforms (the signing entitlement, not `kReleaseMode`). Eliminates the
  footgun; pass it explicitly only to override. Docstring/README warn against
  gating on build mode.

Native fixes (verify on a device — no native CI):

* **iOS/macOS token caching** — `getToken` returns the cached APNs token on a
  second call within a session instead of waiting on a `didRegister` callback
  iOS doesn't reliably re-fire (was a 30s timeout).
* **macOS notification-delegate chaining** — the plugin captures the previous
  `UNUserNotificationCenter.delegate` and forwards `willPresent` / `didReceive`
  to it, instead of clobbering other plugins (e.g. flutter_local_notifications).

## 0.4.0

* **`identify` no longer sends `app_id`.** The backend now derives the app from
  the authenticated device, so `IdentifyRequest` drops its `appId` field and the
  request body is just `{external_user_id, apns_environment?}`. `PokeMe.identify`
  / `IdentityClient.identify` are unchanged (`app_id` was always taken from
  config); only the low-level `IdentifyRequest` constructor is affected.
  **Requires the matching backend change** that makes `app_id` optional on
  `POST /api/v1/devices/me/identify`.

## 0.3.0

* **Service errors no longer vanish.** Previously the SDK threw rich
  `PokeApiException`s on 4xx/5xx but logged nothing, so fire-and-forget calls
  (`unawaited(poke.registerOnLaunch(...))`) lost the error entirely. Now:
  * Every HTTP/transport failure is **logged** via `dart:developer` under the
    `pokeme` name (method, path, status, detail). Toggle with
    `pokemeLoggingEnabled`; dropped non-conformant pushes are logged too.
  * `PokeMe.errors` — a broadcast `Stream<PokeError>` that surfaces failures
    from `registerOnLaunch` / `identify` / `unidentify` / `refreshPushToken`
    **even when fire-and-forget**. Operations still throw for awaiting callers;
    wire `poke.errors.listen(...)` to route them to your telemetry.

## 0.2.1

* **Fix macOS hang on `registerOnLaunch` / `getToken`** (#3). macOS Flutter does
  not forward the APNs registration callback to plugins (its lifecycle delegate
  has no remote-notification methods), so the device token never reached the
  plugin and the future never completed. The macOS plugin now swizzles the host
  `NSApplicationDelegate` to forward `didRegister`/`didFail` — no host AppDelegate
  code required.
* `getToken` now times out (default 30s) and throws a clear `PushTokenException`
  (code `TIMEOUT`) instead of hanging if the callback never arrives.

## 0.2.0

* **Decouple the notification-permission prompt from token fetch** (#1).
  `PushTokenService.getToken` gains a `requestPermission` flag (default true);
  `IdentityClient.registerOnLaunch` and `PokeMe.registerOnLaunch` forward it.
  Pass `requestPermission: false` to register/fetch **without** showing the OS
  prompt — a token is returned only if permission was already granted,
  otherwise it is a silent no-op for `registerOnLaunch`. Lets hosts defer the
  prompt to a contextual moment (Apple HIG). Apple-only; Android never prompts.

## 0.1.0

Initial release — extracted from the poke-me monorepo (history-preserving).

* **BYOA core** — `PokeMe.init` facade plus `IdentityClient`: register an
  anonymous install by client key, `identify` / `unidentify` a subject by
  opaque external user id, push-token refresh.
* **Native push receive** — Android `FirebaseMessagingService` and Apple
  `didReceiveRemoteNotification` / `UNUserNotificationCenter` delegate forward
  incoming pushes to a single `PokeMe.pushes` stream. No `firebase_messaging`
  dependency.
* **Rich envelope parsing** — `parsePushPayload` understands the `origin`
  discriminator (`channel` / `subject`); subject alerts surface `app_id` /
  `external_user_id`.
* **Optional channels layer** — `package:pokeme/channels.dart` adds the
  join-key / routing-key subscription surface and re-exports the core.
* Platform token retrieval (APNs / FCM) and a local SQLite store.
