package io.pokeme.pokeme

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/// Receives FCM messages for whatever app embeds the SDK and forwards their
/// payload to the Flutter side via [PokemePlugin].
///
/// Registered via the plugin's own `AndroidManifest.xml` (merged into the host
/// app), so no host wiring is needed. `onMessageReceived` fires for data
/// messages in the foreground and warm background; terminated-state delivery is
/// not handled here (it would need a background isolate).
class PokemeMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val payload = HashMap<String, Any?>(message.data)
        // Fold in the notification title/body when the push carries a
        // `notification` block rather than (or alongside) data — the SDK reads
        // the same keys regardless of which FCM message type was used.
        message.notification?.let { n ->
            n.title?.let { payload.putIfAbsent("title", it) }
            n.body?.let { payload.putIfAbsent("body", it) }
        }
        PokemePlugin.deliverMessage(payload)
        // Android never auto-displays data-only messages, so render one here
        // (unless the host opted out via PokeMe.init(androidAutoDisplay: false)).
        PokemeNotifications.show(applicationContext, payload)
    }
}
