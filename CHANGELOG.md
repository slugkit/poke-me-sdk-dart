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
