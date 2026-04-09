# PokeMe SDK — Push Notification Setup Guide

This guide covers setting up push notification delivery for Android (FCM) and Apple platforms (APNs). Your backend dispatches directly to both services — Firebase is only used on Android as the mandatory last-mile relay.

## Android — Firebase Cloud Messaging (FCM)

### 1. Create a Firebase project

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Click **Add project** and follow the wizard (analytics is optional)
3. Once created, click **Add app → Android**
4. Enter your Android package name: `io.pokeme.app`
5. Download the generated `google-services.json`

### 2. Add the config file

Place `google-services.json` at:

```
mobile/android/app/google-services.json
```

The build system conditionally applies the Google Services Gradle plugin — it only activates when this file is present. No code changes needed.

> **Note**: `google-services.json` is gitignored because it contains project-specific credentials. Each developer or CI environment needs their own copy.

### 3. Get a service account for your backend

Your backend needs credentials to send pushes via the FCM HTTP v1 API:

1. In Firebase Console → **Project Settings → Service accounts**
2. Click **Generate new private key** — downloads a JSON file
3. Store this securely on your backend server

### 4. Backend dispatch (FCM HTTP v1 API)

```
POST https://fcm.googleapis.com/v1/projects/{project-id}/messages:send
Authorization: Bearer {oauth2-access-token}
Content-Type: application/json

{
  "message": {
    "token": "{fcm-device-token}",
    "notification": {
      "title": "Hello",
      "body": "World"
    }
  }
}
```

The OAuth2 access token is obtained from the service account JSON using Google's auth libraries. The FCM device token is the string your app sends to the backend after calling `PushTokenService().getToken()`.

### 5. Verify

Run the app on a physical Android device or emulator with Google Play Services:

```bash
cd mobile && flutter run
```

The app should display an **FCM Token**. Copy it and use it to send a test push via the API above.

---

## iOS — Apple Push Notification service (APNs)

### 1. Apple Developer account prerequisites

- An [Apple Developer Program](https://developer.apple.com/programs/) membership (£79/year)
- An App ID registered with **Push Notifications** capability

### 2. Register an App ID

1. Go to [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list)
2. Click **+** to register a new identifier
3. Select **App IDs → App**
4. Enter description (e.g. "push") and bundle ID: `io.pokeme.app`
5. Under **Capabilities**, tick **Push Notifications**
6. Click **Continue → Register**

### 3. Generate an APNs Authentication Key (.p8)

This key is used by your backend to authenticate with APNs. One key works for all your apps.

1. Go to [Keys](https://developer.apple.com/account/resources/authkeys/list)
2. Click **+** to create a new key
3. Name it (e.g. "PokeMe APNs Key")
4. Tick **Apple Push Notifications service (APNs)**
5. Click **Continue → Register**
6. **Download the .p8 file** — you can only download it once
7. Note the **Key ID** (10-character string, e.g. `ABC123DEFG`)
8. Note your **Team ID** from [Membership Details](https://developer.apple.com/account/#/membership)

Store the .p8 file, Key ID, and Team ID securely on your backend.

### 4. Configure Xcode

The entitlements are already set up in this project. If you need to verify or change them:

1. Open `mobile/ios/Runner.xcworkspace` in Xcode
2. Select the **Runner** target → **Signing & Capabilities**
3. Ensure **Push Notifications** is listed
4. The `aps-environment` is set to `development` — Xcode automatically switches to `production` for App Store builds

### 5. Provisioning profile

Xcode manages this automatically when "Automatically manage signing" is enabled. If managing manually:

1. Create a provisioning profile at [Profiles](https://developer.apple.com/account/resources/profiles/list)
2. Select your App ID (`io.pokeme.app`)
3. Select the signing certificate
4. Download and install in Xcode

### 6. Backend dispatch (APNs HTTP/2 API)

```
POST https://api.push.apple.com/3/device/{apns-device-token}
authorization: bearer {jwt-token}
apns-topic: io.pokeme.app
apns-push-type: alert

{
  "aps": {
    "alert": {
      "title": "Hello",
      "body": "World"
    }
  }
}
```

**JWT construction** (for token-based authentication):
- **Header**: `{"alg": "ES256", "kid": "{key-id}"}`
- **Payload**: `{"iss": "{team-id}", "iat": {unix-timestamp}}`
- **Sign** with your .p8 private key

The APNs device token is a hex-encoded string (e.g. `a1b2c3d4e5f6...`), which is what the PokeMe SDK returns from `PushTokenService().getToken()` on Apple platforms.

**APNs endpoints:**
- Development: `https://api.sandbox.push.apple.com`
- Production: `https://api.push.apple.com`

### 7. Verify

Run the app on a **physical iOS device** (simulators cannot receive push notifications):

```bash
cd mobile && flutter run
```

The app should display an **APNs Token**. Copy it and use it to send a test push via the API above.

---

## macOS — Apple Push Notification service (APNs)

The same APNs key (.p8) and backend integration work for macOS. The only differences are in the app configuration.

### 1. App ID

Register a separate App ID for macOS at [Identifiers](https://developer.apple.com/account/resources/identifiers/list) if you want a distinct bundle ID for macOS. Otherwise, the same `io.pokeme.app` works.

### 2. Entitlements

Already configured in this project:
- `macos/Runner/DebugProfile.entitlements` — `aps-environment: development`
- `macos/Runner/Release.entitlements` — `aps-environment: production`

### 3. Signing

macOS apps must be signed to receive push notifications, even during development. Ensure your Apple Developer team is configured in Xcode.

### 4. Verify

```bash
cd mobile && flutter run -d macos
```

> **Note**: macOS push tokens use the same APNs infrastructure. Your backend sends to the same APNs endpoint — the token identifies the device and platform.

---

## Token format reference

| Platform | Token type | Format | Length |
|----------|-----------|--------|--------|
| Android  | FCM       | Opaque string (base64-like) | ~163 chars |
| iOS      | APNs      | Hex-encoded device token | 64 chars |
| macOS    | APNs      | Hex-encoded device token | 64 chars |

Your backend should store the token alongside the platform type to know which dispatch path to use (FCM API vs APNs API).

---

## Troubleshooting

### "No APNs token returned" / "Push notifications are unavailable on simulators"
iOS and macOS simulators cannot register for remote notifications. Use a physical device.

### "No FCM token returned. Ensure google-services.json is configured."
The `google-services.json` file is missing from `android/app/`. See the Android setup section above.

### "Notification permission denied"
The user declined the notification permission prompt. On iOS, the prompt only appears once — to re-enable:
1. Open **Settings → Notifications → poke**
2. Enable **Allow Notifications**

On Android 13+, the notification permission can be re-requested, or the user can enable it in **Settings → Apps → poke → Notifications**.

### Token refresh
Push tokens can change at any time (app reinstall, OS update, etc.). The SDK provides `onTokenRefresh` stream to listen for updates. Your backend should update the stored token when a refresh occurs.

### Firebase initialisation errors on Apple platforms
Firebase is only initialised on Android. If you see Firebase-related errors on iOS/macOS, ensure the Dart code guards initialisation with `Platform.isAndroid`.
