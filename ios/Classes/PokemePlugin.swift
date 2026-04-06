import Flutter
import UIKit
import UserNotifications

public class PokemePlugin: NSObject, FlutterPlugin {
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?
    private var tokenStreamHandler: TokenStreamHandler?
    private var pendingTokenResult: FlutterResult?

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

        registrar.addApplicationDelegate(instance)
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

    private func requestTokenWithPermission(result: @escaping FlutterResult) {
        pendingTokenResult = result

        let centre = UNUserNotificationCenter.current()

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

            // Verify the actual status — the request can succeed but the
            // system may still deny notifications (e.g. missing entitlement).
            centre.getNotificationSettings { settings in
                DispatchQueue.main.async {
                    switch settings.authorizationStatus {
                    case .authorized, .provisional, .ephemeral:
                        UIApplication.shared.registerForRemoteNotifications()
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
                                message: "Notifications are not allowed for this application. "
                                    + "Ensure the aps-environment entitlement is included in the provisioning profile.",
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
