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
