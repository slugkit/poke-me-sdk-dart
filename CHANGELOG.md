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
