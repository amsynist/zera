# Zera X approvals

Zera X is the new name for the Android companion. The phone keeps its application ID `com.androp` and the existing file-transfer pairing and Share target. Its **Approvals** screen and the Wear OS companion are optional.

```text
Claude Code permission hook → Zera on Mac ⇄ encrypted local connection ⇄ Zera X phone
                                 ↓                                        ⇅
                                notch                               paired Wear OS watch
```

## Connect your devices

1. Pair the Watch8 with your Android phone in Galaxy Wearable. Install the Zera X phone and Wear OS APKs signed with the same certificate. The watch build declares the same package ID as the phone.
2. Connect the phone and Mac to the same Wi-Fi or connect the Mac to the phone's hotspot. In Zera on the Mac, enable the Claude Code permission hook and restart existing Claude Code sessions if required.
3. Open **Settings → Extras → Zera X approvals**, enable **Send Claude approvals to Android** and reveal the approval QR. In the phone app, open **Approvals → Pair with Mac** and scan it. The Android foreground notification indicates the link is enabled.
4. Open Zera X on the watch and allow notifications. On the phone, tap **Link nearby watch** and select your Watch8. Keep Bluetooth connected. Enable a watch screen lock to approve from the wrist.

## Review and disconnect

The phone lists live Claude Code hook requests with their tool input. Every request can be decided on the watch: it opens full screen, and you drag it right to approve or left to deny. Long actions wrap onto up to four lines; anything over 72 characters or spanning several lines is shortened with "…", and the full text stays on the phone and in the notch. A watch without a screen lock can approve at once; with a lock, approvals wait for an unlock. Notifications display a generic prompt. The phone and watch show **Approved in Zera** or **Denied in Zera** only after the Mac writes the hook response. The result says nothing about whether the tool completed.

The Mac is authoritative. When you answer in Terminal or the notch, the corresponding mobile request closes at the next state update. Decision messages are tied to the exact live request and are never queued offline. The watch disables actions when its request view expires. Captured command text is held in phone memory while the request is pending, and detailed input stays off the watch. This first bridge handles Claude Code's standard permission hook. It has no control over observed desktop sessions, Cursor, or Codex.

Pairing survives restarts and updates. The Mac keeps the approval key in a 0600 file, `~/Library/Application Support/Zera/zerax-approval.key`, beside the hook spool it guards. It reuses its port and turns the bridge back on at launch. The phone seals its copy with a non-exportable Android Keystore key and remembers the linked watch. After an app update or reboot, Zera X reconnects automatically. If the Mac changes address or port, the phone finds it again with Bonjour (`_zerax._tcp`) by a name ending in the first four bytes of SHA-256 of the key.

Turn off **Send Claude approvals to Android** on the Mac to disconnect and delete that key file. Every paired phone must then scan a new QR. **Forget Mac** on Android deletes the stored pairing and stops the foreground service. This approval connection does not change the separately enabled Android file-sharing connection.

## Build and test

```sh
cd android
./gradlew :app:assembleDebug :wear:assembleDebug :app:lintDebug :wear:lintDebug :app:testDebugUnitTest
```

The APKs are at `app/build/outputs/apk/debug/app-debug.apk` and `wear/build/outputs/apk/debug/wear-debug.apk`. The phone APK also ships under the existing `Androp.apk` download filename.

On the Mac, run `swift test --filter MobileApprovalBridgeTests`. It uses a synthetic local mock of a live Claude Code permission spool. Hardware acceptance uses the SM-L320 with the phone locked, watch unlocked, and an ordinary Claude Code request waiting on the Mac.

## Connection details

The approval QR contains an ephemeral 256-bit secret and the Mac's IPv4 address and port. Keep it private. The bridge authenticates and encrypts messages with AES-GCM. Each connection uses a fresh challenge, and each authenticated packet includes its direction and sequence number. The Mac accepts one authenticated phone at a time and revokes the key when the service is disabled. No approval credential is shared with the legacy file receiver.

The watch and phone exchange live messages using Wear OS Data Layer. Zera X requires the device to be reported as Bluetooth-nearby before attempting to send or accept an approval message. Google Play services manages transport and may route encrypted Data Layer traffic through its own infrastructure as connectivity changes. The phone-to-Mac connection is local.
