import Cocoa
import FlutterMacOS
import ObjectiveC
import UserNotifications

public class PokemePlugin: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var messageChannel: FlutterEventChannel?
    private var tokenStreamHandler: TokenStreamHandler?
    private var messageStreamHandler: MessageStreamHandler?
    private var pendingTokenResult: FlutterResult?

    /// Last APNs token (see iOS plugin — avoids re-register round-trips).
    private var cachedDeviceToken: String?

    /// The notification-centre delegate that was installed before ours, so we
    /// can forward calls we don't consume (e.g. flutter_local_notifications)
    /// instead of clobbering it.
    private weak var previousNotificationDelegate: UNUserNotificationCenterDelegate?

    /// Shared instance so the AppDelegate can forward token callbacks.
    public static var shared: PokemePlugin?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = PokemePlugin()
        shared = instance

        let methodChannel = FlutterMethodChannel(
            name: "io.pokeme.pokeme/push_token",
            binaryMessenger: registrar.messenger
        )
        instance.methodChannel = methodChannel
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let streamHandler = TokenStreamHandler()
        instance.tokenStreamHandler = streamHandler

        let eventChannel = FlutterEventChannel(
            name: "io.pokeme.pokeme/push_token_refresh",
            binaryMessenger: registrar.messenger
        )
        eventChannel.setStreamHandler(streamHandler)
        instance.eventChannel = eventChannel

        let messageStreamHandler = MessageStreamHandler()
        instance.messageStreamHandler = messageStreamHandler

        let messageChannel = FlutterEventChannel(
            name: "io.pokeme.pokeme/push_messages",
            binaryMessenger: registrar.messenger
        )
        messageChannel.setStreamHandler(messageStreamHandler)
        instance.messageChannel = messageChannel

        // Become the notification-centre delegate (required on macOS for the
        // auth dialog), but chain to whoever was there before so we don't break
        // other plugins (e.g. flutter_local_notifications) — and vice-versa.
        instance.previousNotificationDelegate =
            UNUserNotificationCenter.current().delegate
        UNUserNotificationCenter.current().delegate = instance

        // Unlike iOS, macOS Flutter does not relay the APNs registration
        // callbacks (`application:didRegisterForRemoteNotificationsWithDeviceToken:`)
        // to plugins — `FlutterAppLifecycleDelegate` carries no
        // remote-notification methods. Without this, the device token never
        // reaches the plugin and `getToken` hangs. Forward it by swizzling the
        // host's NSApplicationDelegate, so no host AppDelegate code is needed.
        instance.installRemoteNotificationForwarding()
    }

    /// Installs APNs registration forwarding onto the host's
    /// `NSApplicationDelegate` by swizzling. Idempotent enough for a single
    /// plugin registration; safe no-op if no app delegate is set yet.
    private func installRemoteNotificationForwarding() {
        guard let appDelegate = NSApplication.shared.delegate else { return }
        let cls: AnyClass = type(of: appDelegate)

        let registerSel = #selector(
            NSApplicationDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:))
        if let method = class_getInstanceMethod(cls, registerSel) {
            let original = method_getImplementation(method)
            typealias Fn = @convention(c) (AnyObject, Selector, NSApplication, Data) -> Void
            let block: @convention(block) (AnyObject, NSApplication, Data) -> Void = {
                receiver, app, token in
                PokemePlugin.shared?.didRegisterForRemoteNotifications(deviceToken: token)
                unsafeBitCast(original, to: Fn.self)(receiver, registerSel, app, token)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        } else {
            let block: @convention(block) (AnyObject, NSApplication, Data) -> Void = {
                _, _, token in
                PokemePlugin.shared?.didRegisterForRemoteNotifications(deviceToken: token)
            }
            class_addMethod(cls, registerSel, imp_implementationWithBlock(block), "v@:@@")
        }

        let failSel = #selector(
            NSApplicationDelegate.application(_:didFailToRegisterForRemoteNotificationsWithError:))
        if let method = class_getInstanceMethod(cls, failSel) {
            let original = method_getImplementation(method)
            typealias Fn = @convention(c) (AnyObject, Selector, NSApplication, NSError) -> Void
            let block: @convention(block) (AnyObject, NSApplication, NSError) -> Void = {
                receiver, app, error in
                PokemePlugin.shared?.didFailToRegisterForRemoteNotifications(error: error)
                unsafeBitCast(original, to: Fn.self)(receiver, failSel, app, error)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        } else {
            let block: @convention(block) (AnyObject, NSApplication, NSError) -> Void = {
                _, _, error in
                PokemePlugin.shared?.didFailToRegisterForRemoteNotifications(error: error)
            }
            class_addMethod(cls, failSel, imp_implementationWithBlock(block), "v@:@@")
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getToken":
            let requestPermission =
                (call.arguments as? [String: Any])?["requestPermission"] as? Bool ?? true
            requestToken(requestPermission: requestPermission, result: result)
        case "openSettings":
            openNotificationSettings(result: result)
        case "getApnsEnvironment":
            result(Self.detectApnsEnvironment())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Reads the `aps-environment` entitlement from the embedded provisioning
    /// profile (macOS: `Contents/embedded.provisionprofile`). Returns
    /// `"sandbox"` / `"production"`, or nil when there is no embedded profile
    /// (App Store builds) — the caller then falls back to its configured value.
    static func detectApnsEnvironment() -> String? {
        guard
            let path = Bundle.main.path(
                forResource: "embedded", ofType: "provisionprofile"),
            let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let text = String(data: raw, encoding: .isoLatin1),
            let start = text.range(of: "<?xml"),
            let end = text.range(of: "</plist>")
        else { return nil }

        let plistText = String(text[start.lowerBound..<end.upperBound])
        guard
            let plistData = plistText.data(using: .isoLatin1),
            let plist = try? PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil) as? [String: Any],
            let entitlements = plist["Entitlements"] as? [String: Any],
            let aps = entitlements["aps-environment"] as? String
        else { return nil }

        return aps == "production" ? "production" : "sandbox"
    }

    private func openNotificationSettings(result: @escaping FlutterResult) {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        // Open the app-specific notification settings page in System Settings.
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleId)") {
            NSWorkspace.shared.open(url)
        }
        result(nil)
    }

    /// Fetches the APNs token. When [requestPermission] is true, shows the
    /// system authorisation dialog the first time; when false, no dialog is
    /// shown — registration proceeds only if already authorised.
    private func requestToken(requestPermission: Bool, result: @escaping FlutterResult) {
        pendingTokenResult = result

        let centre = UNUserNotificationCenter.current()

        // Check current status first.
        centre.getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    if let cached = self.cachedDeviceToken {
                        self.completePending(cached)
                    } else {
                        NSApplication.shared.registerForRemoteNotifications()
                    }

                case .denied:
                    // Previously denied — can't show the dialog again.
                    self.completePending(
                        FlutterError(
                            code: "PERMISSION_DENIED",
                            message: "Notification permission denied. "
                                + "Enable notifications in System Settings → Notifications → poke.",
                            details: nil
                        )
                    )

                case .notDetermined:
                    if requestPermission {
                        // Request authorisation (shows the system dialog).
                        self.requestAuthorisation(centre: centre)
                    } else {
                        // Deferred — do not prompt.
                        self.completePending(
                            FlutterError(
                                code: "PERMISSION_NOT_DETERMINED",
                                message: "Notification permission has not been requested yet. "
                                    + "Call getToken(requestPermission: true) at a contextual moment.",
                                details: nil
                            )
                        )
                    }

                @unknown default:
                    if requestPermission {
                        self.requestAuthorisation(centre: centre)
                    } else {
                        self.completePending(
                            FlutterError(
                                code: "PERMISSION_NOT_DETERMINED",
                                message: "Notification permission has not been requested yet.",
                                details: nil
                            )
                        )
                    }
                }
            }
        }
    }

    private func requestAuthorisation(centre: UNUserNotificationCenter) {
        centre.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            DispatchQueue.main.async {
                if let error = error {
                    self.completePending(
                        FlutterError(
                            code: "PERMISSION_ERROR",
                            message: error.localizedDescription,
                            details: nil
                        )
                    )
                    return
                }

                if !granted {
                    self.completePending(
                        FlutterError(
                            code: "PERMISSION_DENIED",
                            message: "Notification permission denied. "
                                + "Enable notifications in System Settings → Notifications → poke.",
                            details: nil
                        )
                    )
                    return
                }

                NSApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    private func completePending(_ value: Any?) {
        guard let pending = pendingTokenResult else { return }
        pendingTokenResult = nil
        pending(value)
    }

    /// Called by the AppDelegate when a device token is received.
    public func didRegisterForRemoteNotifications(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        cachedDeviceToken = token
        completePending(token)
        tokenStreamHandler?.send(token: token)
    }

    /// Called by the AppDelegate when registration fails.
    public func didFailToRegisterForRemoteNotifications(error: Error) {
        let nsError = error as NSError
        let message: String

        if nsError.domain == NSOSStatusErrorDomain && nsError.code == 13 {
            message = "Push notifications are not configured. "
                + "Ensure the App ID has Push Notifications enabled in the Apple Developer portal, "
                + "then regenerate the provisioning profile "
                + "(Xcode → Runner → Signing & Capabilities → untick and re-tick 'Automatically manage signing')."
        } else {
            message = error.localizedDescription
        }

        completePending(
            FlutterError(
                code: "REGISTRATION_FAILED",
                message: message,
                details: nil
            )
        )
    }

    /// Called by the AppDelegate for silent / background remote notifications
    /// (which do not pass through the notification centre delegate).
    public func deliverRemoteNotification(userInfo: [AnyHashable: Any]) {
        messageStreamHandler?.send(payload: PokemePlugin.extractPayload(userInfo))
    }

    /// Flattens the APNs `userInfo` to a Flutter-codec-friendly `[String: Any]`,
    /// dropping the `aps` envelope so only the publisher's custom keys remain.
    static func extractPayload(_ userInfo: [AnyHashable: Any]) -> [String: Any] {
        var payload: [String: Any] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String, key != "aps" else { continue }
            payload[key] = value
        }
        return payload
    }

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Always observe the payload …
        deliverRemoteNotification(userInfo: notification.request.content.userInfo)
        // … then let the previously-installed delegate decide presentation (and
        // own the completion handler); only present ourselves if there is none.
        if let prev = previousNotificationDelegate,
            prev.responds(
                to: #selector(UNUserNotificationCenterDelegate
                    .userNotificationCenter(_:willPresent:withCompletionHandler:))) {
            prev.userNotificationCenter?(
                center, willPresent: notification,
                withCompletionHandler: completionHandler)
        } else {
            completionHandler([.banner, .badge, .sound])
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        deliverRemoteNotification(userInfo: response.notification.request.content.userInfo)
        if let prev = previousNotificationDelegate,
            prev.responds(
                to: #selector(UNUserNotificationCenterDelegate
                    .userNotificationCenter(_:didReceive:withCompletionHandler:))) {
            prev.userNotificationCenter?(
                center, didReceive: response,
                withCompletionHandler: completionHandler)
        } else {
            completionHandler()
        }
    }
}

private class TokenStreamHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    func send(token: String) {
        eventSink?(token)
    }
}

private class MessageStreamHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    func send(payload: [String: Any]) {
        eventSink?(payload)
    }
}
