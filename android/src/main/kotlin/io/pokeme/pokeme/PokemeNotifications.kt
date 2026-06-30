package io.pokeme.pokeme

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/// Renders incoming pushes as system notifications on Android.
///
/// The backend sends data-only FCM messages (so the SDK always receives them),
/// which Android never auto-displays — unlike APNs alerts on iOS/macOS. This
/// helper closes that gap: it posts a [NotificationCompat] for alert payloads.
/// Controlled by a persisted flag ([setConfig]) so a host that owns its own
/// notification UI can opt out via `PokeMe.init(androidAutoDisplay: false)`.
object PokemeNotifications {
    private const val PREFS = "io.pokeme.pokeme.prefs"
    private const val KEY_AUTO_DISPLAY = "auto_display"
    private const val KEY_CHANNEL_ID = "channel_id"
    private const val KEY_CHANNEL_NAME = "channel_name"
    private const val DEFAULT_CHANNEL_ID = "pokeme_default"
    private const val DEFAULT_CHANNEL_NAME = "Notifications"

    /// Persists the auto-display flag (and optional channel id/name) so the
    /// system-instantiated [PokemeMessagingService] can read it, even on a cold
    /// start where no plugin instance exists.
    fun setConfig(
        context: Context,
        autoDisplay: Boolean,
        channelId: String?,
        channelName: String?
    ) {
        val editor = prefs(context).edit().putBoolean(KEY_AUTO_DISPLAY, autoDisplay)
        if (channelId != null) editor.putString(KEY_CHANNEL_ID, channelId)
        if (channelName != null) editor.putString(KEY_CHANNEL_NAME, channelName)
        editor.apply()
        ensureChannel(context)
    }

    /// Posts a notification for an alert [payload] (a map with `title` / `body`
    /// / `priority` / `id` / …). No-op when auto-display is off or the payload
    /// has no displayable content (e.g. a system event).
    fun show(context: Context, payload: Map<String, Any?>) {
        if (!prefs(context).getBoolean(KEY_AUTO_DISPLAY, true)) return
        val title = payload["title"] as? String
        val body = payload["body"] as? String
        if (title == null && body == null) return

        ensureChannel(context)

        val builder = NotificationCompat.Builder(context, channelId(context))
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setPriority(priorityFor(payload["priority"] as? String))

        contentIntent(context, payload)?.let { builder.setContentIntent(it) }

        val id = (payload["id"] as? String)?.hashCode() ?: System.currentTimeMillis().toInt()
        // No-op if POST_NOTIFICATIONS isn't granted (Android 13+); the plugin
        // requests it during getToken.
        NotificationManagerCompat.from(context).notify(id, builder.build())
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    channelId(context),
                    channelName(context),
                    NotificationManager.IMPORTANCE_HIGH
                )
            )
        }
    }

    /// Tap action: relaunch the host app, carrying the payload as `pokeme_*`
    /// extras so the app can route (plus `pokeme_tapped = true`).
    private fun contentIntent(context: Context, payload: Map<String, Any?>): PendingIntent? {
        val launch = context.packageManager
            .getLaunchIntentForPackage(context.packageName) ?: return null
        launch.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        launch.putExtra("pokeme_tapped", true)
        for ((key, value) in payload) {
            if (value is String) launch.putExtra("pokeme_$key", value)
        }
        return PendingIntent.getActivity(
            context,
            (payload["id"] as? String)?.hashCode() ?: 0,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun channelId(context: Context) =
        prefs(context).getString(KEY_CHANNEL_ID, null) ?: DEFAULT_CHANNEL_ID

    private fun channelName(context: Context) =
        prefs(context).getString(KEY_CHANNEL_NAME, null) ?: DEFAULT_CHANNEL_NAME

    private fun priorityFor(priority: String?) = when (priority) {
        "low" -> NotificationCompat.PRIORITY_LOW
        "high", "critical" -> NotificationCompat.PRIORITY_HIGH
        else -> NotificationCompat.PRIORITY_DEFAULT
    }
}
