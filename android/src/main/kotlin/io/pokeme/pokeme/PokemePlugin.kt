package io.pokeme.pokeme

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry

class PokemePlugin : FlutterPlugin, MethodCallHandler, ActivityAware,
    EventChannel.StreamHandler, PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.NewIntentListener {

    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var messageEventChannel: EventChannel
    private var activityBinding: ActivityPluginBinding? = null
    private var activity: Activity? = null
    private var eventSink: EventChannel.EventSink? = null
    private var pendingTokenResult: Result? = null

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
            "getToken" -> getToken(call, result)
            "openSettings" -> openSettings(result)
            "configureAndroidNotifications" -> {
                val context = activity?.applicationContext
                if (context != null) {
                    PokemeNotifications.setConfig(
                        context,
                        autoDisplay = call.argument<Boolean>("autoDisplay") ?: true,
                        channelId = call.argument<String>("channelId"),
                        channelName = call.argument<String>("channelName"),
                    )
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun getToken(call: MethodCall, result: Result) {
        val activity = this.activity ?: run {
            result.error("NO_ACTIVITY", "No activity available", null)
            return
        }
        val requestPermission = call.argument<Boolean>("requestPermission") ?: true

        // Android 13+ gates notification display behind the POST_NOTIFICATIONS
        // runtime permission. Request it (when allowed to prompt) before
        // fetching the token; older versions need no runtime grant.
        if (requestPermission &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            pendingTokenResult = result
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                POST_NOTIFICATIONS_REQUEST,
            )
            return
        }

        fetchToken(result)
    }

    private fun fetchToken(result: Result) {
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

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != POST_NOTIFICATIONS_REQUEST) return false
        val result = pendingTokenResult ?: return true
        pendingTokenResult = null
        if (grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        ) {
            fetchToken(result)
        } else {
            result.error(
                "PERMISSION_DENIED",
                "Notification permission denied.",
                null
            )
        }
        return true
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
        private const val POST_NOTIFICATIONS_REQUEST = 7001

        /// What this device observed about a notification, tagged onto every
        /// event so the Dart side can report a delivery receipt without the
        /// host wiring anything. Must match `PushService.signalKey` and
        /// `ReceiptState`.
        const val SIGNAL_KEY = "_pokeme_signal"
        const val SIGNAL_DELIVERED = "delivered"
        const val SIGNAL_SHOWN = "shown"
        const val SIGNAL_OPENED = "opened"

        /// Forwards a bare signal: an id and what happened to it, with no
        /// envelope. Used for things that happened to a notification whose
        /// payload was already delivered — the OS displayed it, or the user
        /// tapped it. The Dart side reports these and does not re-broadcast
        /// them, so a host that already saw the push does not see it twice.
        fun deliverSignal(notificationId: String?, signal: String) {
            if (notificationId.isNullOrEmpty()) return
            deliverMessage(mapOf(SIGNAL_KEY to signal, "id" to notificationId))
        }
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
        bindActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        unbindActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        bindActivity(binding)
    }

    override fun onDetachedFromActivity() {
        unbindActivity()
    }

    private fun bindActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
        binding.addOnNewIntentListener(this)
        // A tap that cold-started the app arrives as the launch intent rather
        // than through onNewIntent, so it has to be read here or it is missed
        // entirely — which is the tap most worth knowing about.
        reportTap(binding.activity.intent)
    }

    private fun unbindActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
        activity = null
    }

    /// A tap on a notification the SDK posted, which relaunches the host with
    /// the payload as `pokeme_*` extras (see [PokemeNotifications]).
    ///
    /// The extra is cleared once read: Android hands the same intent back on
    /// every configuration change, and reporting a tap once per screen rotation
    /// would be wrong in a way nothing downstream could correct.
    override fun onNewIntent(intent: Intent): Boolean {
        reportTap(intent)
        // Never consume it — the host's own routing reads the same extras.
        return false
    }

    private fun reportTap(intent: Intent?) {
        if (intent == null) return
        if (!intent.getBooleanExtra("pokeme_tapped", false)) return
        deliverSignal(intent.getStringExtra("pokeme_id"), SIGNAL_OPENED)
        intent.removeExtra("pokeme_tapped")
    }
}
