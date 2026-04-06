import Cocoa
import FlutterMacOS
import UserNotifications

public class PokemePlugin: NSObject, FlutterPlugin, UNUserNotificationCenterDelegate {
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var tokenStreamHandler: TokenStreamHandler?
    private var pendingTokenResult: FlutterResult?

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

        // Set ourselves as the notification centre delegate — required on macOS
        // for the authorisation dialog to appear.
        UNUserNotificationCenter.current().delegate = instance
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getToken":
            requestTokenWithPermission(result: result)
        case "openSettings":
            openNotificationSettings(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func openNotificationSettings(result: @escaping FlutterResult) {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        // Open the app-specific notification settings page in System Settings.
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleId)") {
            NSWorkspace.shared.open(url)
        }
        result(nil)
    }

    private func requestTokenWithPermission(result: @escaping FlutterResult) {
        pendingTokenResult = result

        let centre = UNUserNotificationCenter.current()

        // Check current status first.
        centre.getNotificationSettings { settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    // Already authorised — go straight to registration.
                    NSApplication.shared.registerForRemoteNotifications()

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
                    // First time — request authorisation (shows the system dialog).
                    self.requestAuthorisation(centre: centre)

                @unknown default:
                    self.requestAuthorisation(centre: centre)
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

    // MARK: - UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .badge, .sound])
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
