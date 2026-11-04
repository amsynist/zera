# Androp — Zera’s Android companion

The gallery-first Android app sends original files and text to Zera on the same local Wi-Fi or hotspot. The Mac receiver is already inside Zera. The optional four-edge overlay can receive global drags exported by other apps; Share → Androp remains the fallback. A caught image is held at the edge until you push it across or retract it.

Build with JDK 17, Android SDK 35 and the supplied Gradle wrapper:

```sh
cd android
./gradlew :app:assembleDebug :app:lintDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

The repository-root Androp.apk is the tested debug-signed build. This is a sideloadable APK, not a Play Store release. Gallery access is selected-photo/media permission; the Files tab offers Android’s special shared-storage access. Grant only the features you use. Original bytes stream from content URIs with an eight-chunk window, SHA-256 and final save confirmation. There is no fixed v3 file-size cap.

The dependency-free `:drag-source` fixture and app instrumentation test cross-app URI grants. `am instrument -e media seed` / `-e media share` on the disposable test emulator generate only synthetic gallery artwork and record the real sharing gesture. Never run those fixture modes on a personal phone.

See ../docs/ANDROID_SHARING.md and ../docs/ANDROID_PROTOCOL.md for pairing, behavior and limits.
