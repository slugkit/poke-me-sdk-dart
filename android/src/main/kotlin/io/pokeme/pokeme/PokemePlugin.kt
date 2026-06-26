package io.pokeme.pokeme

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class PokemePlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    EventChannel.StreamHandler {

    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var messageEventChannel: EventChannel
    private var activity: Activity? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "io.pokeme.pokeme/push_token")
        channel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, "io.pokeme.pokeme/push_token_refresh")
        eventChannel.setStreamHandler(this)

        messageEventChannel = EventChannel(binding.binaryMessenger, "io.pokeme.pokeme/push_messages")
        messageEventChannel.setStreamHandler(messageStreamHandler)

        // Listen for token refreshes.
        FirebaseMessaging.getInstance().token.addOnSuccessListener { /* initial fetch handled by getToken */ }
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "getToken" -> getToken(result)
            "openSettings" -> openSettings(result)
            else -> result.notImplemented()
        }
    }

    private fun getToken(result: Result) {
        val context = activity ?: run {
            result.error("NO_ACTIVITY", "No activity available", null)
            return
        }

        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) {
            result.error(
                "PERMISSION_DENIED",
                "Notification permission denied. Enable notifications in device Settings.",
                null
            )
            return
        }

        FirebaseMessaging.getInstance().token
            .addOnSuccessListener { token ->
                if (token.isNullOrEmpty()) {
                    result.error(
                        "TOKEN_UNAVAILABLE",
                        "No FCM token returned. Ensure google-services.json is configured.",
                        null
                    )
                } else {
                    result.success(token)
                }
            }
            .addOnFailureListener { e ->
                result.error(
                    "REGISTRATION_FAILED",
                    e.localizedMessage ?: "Failed to get FCM token",
                    null
                )
            }
    }

    private fun openSettings(result: Result) {
        val context = activity ?: run {
            result.error("NO_ACTIVITY", "No activity available", null)
            return
        }

        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            }
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = android.net.Uri.parse("package:${context.packageName}")
            }
        }
        context.startActivity(intent)
        result.success(null)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        messageEventChannel.setStreamHandler(null)
    }

    // EventChannel.StreamHandler — token refresh channel.
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    // Incoming-message channel. A separate handler because the system
    // instantiates [PokemeMessagingService] independently of this plugin, so the
    // message sink is held statically (see the companion object) for it to reach.
    private val messageStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            attachMessageSink(events)
        }

        override fun onCancel(arguments: Any?) {
            attachMessageSink(null)
        }
    }

    companion object {
        private val mainHandler = Handler(Looper.getMainLooper())
        private val lock = Any()
        private var messageSink: EventChannel.EventSink? = null
        private val pending = ArrayDeque<Map<String, Any?>>()

        /// Forwards an incoming push payload to Dart. Safe to call from any
        /// thread (e.g. the messaging service's background thread). Payloads that
        /// arrive before a Dart listener is attached are buffered and flushed on
        /// attach.
        fun deliverMessage(payload: Map<String, Any?>) {
            synchronized(lock) {
                val sink = messageSink
                if (sink != null) {
                    mainHandler.post { sink.success(payload) }
                } else {
                    pending.addLast(payload)
                }
            }
        }

        private fun attachMessageSink(sink: EventChannel.EventSink?) {
            synchronized(lock) {
                messageSink = sink
                if (sink != null) {
                    while (pending.isNotEmpty()) {
                        val payload = pending.removeFirst()
                        mainHandler.post { sink.success(payload) }
                    }
                }
            }
        }
    }

    // ActivityAware
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    override fun onDetachedFromActivity() {
        activity = null
    }
}
