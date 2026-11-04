# Android companion guide

The root AGENTS.md applies. Kotlin + native Views, min API 26, target/compile 35, JDK 17. The gallery, Files tab and settings are in app/src/main/java/com/androp/ui. MediaGrid uses selected-photo/media permission; FileBrowser offers optional MANAGE_EXTERNAL_STORAGE through Android’s own flow. Do not claim the app needs no broad permission when the Files feature requests it.

AndropConnection owns the one process socket, URI streaming, bounded eight-chunk window, direct thread-safe ACK channels and final verified-result wait. UI observers stay on main; URI reads and hashing stay off it. Do not buffer or JPEG-recompress originals. EdgeGestureDetector uses raw screen coordinates, actual picture/card geometry and all four automatic edges. Cancellation/retraction never commits.

The background service is opt-in, with four 6px seams and larger drop targets during global drags. Another app must export a global drag; retain Share → Androp. EdgeDropActivity owns URI grants and a temporary split picture. A caught picture must be pushed across or retracted, not silently auto-sent. Its thumbnail must match the picture shown on the Mac.

Build `./gradlew :app:assembleDebug :app:lintDebug`. The drag-source subproject is inside android/drag-source in this repository. SmokeInstrumentation includes test-only media seed/share modes using synthetic artwork. These modes are only for a disposable emulator, never a personal phone. Rebuild and copy app/build/outputs/apk/debug/app-debug.apk to ../Androp.apk after production edits. See README.md here and ../docs/ANDROID_PROTOCOL.md.
