import Flutter
import UIKit
import UserNotifications

public class PokemePlugin: NSObject, FlutterPlugin {
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var messageChannel: FlutterEventChannel?
    private var tokenStreamHandler: TokenStreamHandler?
    private var messageStreamHandler: MessageStreamHandler?
    private var pendingTokenResult: FlutterResult?

    /// Last APNs token from `didRegister`. iOS does not always re-fire the
    /// callback on a second `registerForRemoteNotifications()` in the same
    /// session, so we return this cached value instead of waiting (and timing
    /// out) — refreshed whenever the OS issues a new token.
    private var cachedDeviceToken: String?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = PokemePlugin()

        let methodChannel = FlutterMethodChannel(
            name: "io.pokeme.pokeme/push_token",
            binaryMessenger: registrar.messenger()
        )
        instance.methodChannel = methodChannel
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let streamHandler = TokenStreamHandler()
        instance.tokenStreamHandler = streamHandler

        let eventChannel = FlutterEventChannel(
            name: "io.pokeme.pokeme/push_token_refresh",
            binaryMessenger: registrar.messenger()
        )
        eventChannel.setStreamHandler(streamHandler)
        instance.eventChannel = eventChannel

        let messageStreamHandler = MessageStreamHandler()
        instance.messageStreamHandler = messageStreamHandler

        let messageChannel = FlutterEventChannel(
            name: "io.pokeme.pokeme/push_messages",
            binaryMessenger: registrar.messenger()
        )
        messageChannel.setStreamHandler(messageStreamHandler)
        instance.messageChannel = messageChannel

        registrar.addApplicationDelegate(instance)
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
    /// profile so the Dart side need not guess. Returns `"sandbox"` /
    /// `"production"`, or nil for App Store builds (no embedded profile) — the
    /// caller then falls back to its configured value.
    static func detectApnsEnvironment() -> String? {
        guard
            let path = Bundle.main.path(
                forResource: "embedded", ofType: "mobileprovision"),
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
        let urlString: String
        if #available(iOS 16.0, *) {
            urlString = UIApplication.openNotificationSettingsURLString
        } else {
            urlString = UIApplication.openSettingsURLString
        }
        if let url = URL(string: urlString) {
            UIApplication.shared.open(url)
        }
        result(nil)
    }

    /// Fetches the APNs token. When [requestPermission] is true, shows the
    /// system authorisation prompt if the user hasn't been asked; when false,
    /// no prompt is shown — registration proceeds only if already authorised,
    /// otherwise a permission error is returned.
    private func requestToken(requestPermission: Bool, result: @escaping FlutterResult) {
        pendingTokenResult = result

        let centre = UNUserNotificationCenter.current()

        if requestPermission {
            centre.requestAuthorization(options: [.alert, .badge, .sound]) { _, error in
                if let error = error {
                    DispatchQueue.main.async {
                        self.completePending(
                            FlutterError(
                                code: "PERMISSION_ERROR",
                                message: error.localizedDescription,
                                details: nil
                            )
                        )
                    }
                    return
                }
                self.registerIfAuthorised(centre)
            }
        } else {
            registerIfAuthorised(centre)
        }
    }

    /// Registers for remote notifications iff already authorised; never prompts.
    private func registerIfAuthorised(_ centre: UNUserNotificationCenter) {
        centre.getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    if let cached = self.cachedDeviceToken {
                        // Already have a token this session — return it without
                        // waiting on a callback iOS may not re-fire.
                        self.completePending(cached)
                    } else {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                case .denied:
                    self.completePending(
                        FlutterError(
                            code: "PERMISSION_DENIED",
                            message: "Notification permission denied. "
                                + "Enable notifications in Settings → Notifications → poke.",
                            details: nil
                        )
                    )
                case .notDetermined:
                    self.completePending(
                        FlutterError(
                            code: "PERMISSION_NOT_DETERMINED",
                            message: "Notification permission has not been requested yet. "
                                + "Call getToken(requestPermission: true) at a contextual moment.",
                            details: nil
                        )
                    )
                @unknown default:
                    self.completePending(
                        FlutterError(
                            code: "PERMISSION_UNKNOWN",
                            message: "Unknown notification authorisation status",
                            details: nil
                        )
                    )
                }
            }
        }
    }

    private func completePending(_ value: Any?) {
        guard let pending = pendingTokenResult else { return }
        pendingTokenResult = nil
        pending(value)
    }

    // MARK: - UIApplicationDelegate

    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        cachedDeviceToken = token
        completePending(token)
        tokenStreamHandler?.send(token: token)
    }

    public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        completePending(
            FlutterError(
                code: "REGISTRATION_FAILED",
                message: error.localizedDescription,
                details: nil
            )
        )
    }

    public func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) -> Bool {
        messageStreamHandler?.send(payload: PokemePlugin.extractPayload(userInfo))
        completionHandler(.newData)
        return true
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
