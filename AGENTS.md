# Zera v2 project guide

Read README.md and docs/ANDROID_SHARING.md first. This is a native macOS Swift/AppKit/SwiftUI app, with the Android companion source in android/ and its downloadable APK at repository root. The static GitHub Pages site is site/. The release name is Zera v2 (never Zera 2); the app/bundle remains Zera. VERSION is the numeric release version (2.0.0); build.sh reads it unless ZERA_VERSION overrides it.

## Product and architecture

Zera’s existing IslandView is the shared notch container; do not add parallel floating status panels. CardKind raw values persist: append new cases rather than reordering them. Isle defines navigation and header geometry. ZeraController owns presentation, explicit dismissal, activity priorities and lifecycle. The LivingCompanionView is shared and animated on ZeraAnimationClock; preserve teardown and Reduce Motion.

Home, Agents, Shelf, Clipboard, Tasks, PRs, Reminders, Alerts, Focus, Teleprompter, Settings and optional App Shortcuts share native controls and theme tokens. Agents combines Claude and Codex; managed sessions support interaction, observed desktop chats are read-only. Do not imply the watcher can control a desktop session. Murmur uses pinned WhisperKit for optional on-device speech after a model download. Permissions and provider selection remain explicit.

## Android sharing

The receiver is in-process through Packages/AndropKit, not a helper app. Read Sources/Zera/Androp/AGENTS.md, Packages/AndropKit/AGENTS.md and docs/ANDROID_PROTOCOL.md before changing transfers. Default port 8989 and Bonjour _androp._tcp remain compatible. Retain valid previous Androp pairing codes; only one receiver may own the port. Manual endpoints stay pinned.

Android is gallery-first, with a Files tab and opt-in global-drag edge overlay. A global source must export its drag; no universal Instagram/Gallery promise. System-dropped pictures are caught at the edge, then pushed across or retracted. All four edges work; gesture direction is not physical Wi-Fi position sensing. Share → Androp is the fallback.

Wire v3 streams original content URIs in 256 KiB chunks, at most eight / 2 MiB in flight, with ordered cumulative write ACKs. Only final verified RESULT means saved. Preserve filenames safely, original bytes, incremental SHA-256, free-space reserve, peer ownership and partial cleanup. No fixed v3 file cap. Only legacy v2 base64 has the old 8 MiB cap. Traffic is paired but unencrypted on trusted LAN/hotspot; no cloud relay or Bluetooth transport.

The latest photo/video/text behavior is intentional: the picture follows the actual swipe, lands on the desktop and opens after the verified save; a slow/error transfer can show the notch receipt. Ordinary files drop into the notch, Zera catches them, its themed liquid fills with acknowledged bytes, then the verified original is referenced on Shelf. No automatic analysis. The phone’s shared thumbnail is the picture seen on the Mac. Do not regress to a generic card for a photo or a permanent extra receipt on the desktop. Old-generation cleanup must not hide a newer transfer or a screen the user selected.

The user rejected separate receipt panels, plain progress cards and contrasting violet/red wave bands. Use active-theme tonal depth, a coherent liquid surface and readable file information. Keep the current source’s island rim, catch/pour gestures, natural picture sizes and swallowing behavior. Use cached Core Animation layers and vector masks; no per-frame full-screen blur/SwiftUI rebuilding, strobing or new audio capture.

## Build and checks

- `swift test` — full native suite; visual recordings skip unless explicitly enabled.
- `swift test --package-path Packages/AndropKit` — peer ownership, filesystem safety, streaming integrity and arrival geometry.
- `ZERA_TEST_ANDROID_INBOX=/private/tmp/zera-test swift test --filter AndroidTransferTests` — opt-in 100 MiB host/Shelf check, synthetic data only.
- `cd android && JAVA_HOME=/path/to/jdk17 ./gradlew :app:assembleDebug :app:lintDebug` — Android SDK 35.
- `node scripts/check-site.mjs` — static assets, gallery keyboard/ARIA, media lifecycle and download URL allowlist.
- `./build.sh` — local app. Preserve the stable local signing identity when .rea/local-sign.sh exists; never silently replace it with ad-hoc signing. Do not publish private signer/config files. Developer ID signing is not the same as notarization.

Refresh root Androp.apk after Android production changes and update checksums. The test-only drag-source app never goes in that APK. Keep the Kotlin sender, Swift receiver, protocol docs and simulator synchronized. The repository is self-contained; do not copy an old adjacent-checkout snapshot over newer reviewed source.

## Release and media

Use repository-local git identity amsynist / pravinblogging@gmail.com; do not alter global identity. Verify the base against freshly fetched origin/main before a new release branch. Current release work is release/zera-v2, originally based at 6d140283c45d3aa0495389b34a9c4fdb45d217b4. Push the review branch; merging main, tagging or publishing a live release is separate from preparing the branch.

Sharing is the lead README/site feature. The launch film uses real Androp on the left and actual Mac photo arrival on the right, with restrained 3D device framing, clean demo desktop and “No internet. Just Wi-Fi.” Keep the sharing film dedicated to photo/file sharing: no notch feature tour or unrelated app screens. Use large, readable kinetic captions, purposeful continuous zooms and high-cadence native source capture. The latest direction adds an animated full-frame hex-grid backdrop, clear Android-left/MacBook-right hardware labels, real photorealistic generated gallery assets, and the native fixture’s animated teal wallpaper. Keep the Mac source live for the entire film; do not freeze its wallpaper during intro/outro holds. Export a clean wallpaper separately when requested, without the notch/character. The first Mac take used a slow CG/JPEG loop; the replacement opt-in fixture uses ScreenCaptureKit hardware recording at requested 60fps, filtering only its own windows and the exact newly opened synthetic-photo Preview window. Never add arbitrary Preview windows or a full personal desktop to the filter. Real transfer footage is not a latency benchmark. Preserve current screen captures and use synthetic artwork and fictional tasks; never publish real clipboard/session/calendar/desktop data. See docs/MEDIA.md for reproducible captures. Refresh site, README and versioned release notes together.

Private .rea/, .mcp.json, 0/ self-test desktops, .env, build outputs and long audit notebooks stay out of commits. Local signature identities, keychains, model caches and recordings with personal content are never release assets. Native capture helpers must whitelist their own windows and the exact demo image; never silently record the user’s entire desktop.

The full walkthrough is now a separate 80-second/60fps kinetic film with 27 captioned chapters, fresh native hardware source, focus moves and real window arrangements. `testRecordV2Release` uses ScreenCaptureKit and SCScreenshotManager on macOS 15+; it records only its fixture window. Its floating demo animation is explicitly ticked while recording because the production clock correctly pauses occluded views; ZERA_V2_MEDIA_ONLY=water records a replacement scene. Do not remove production occlusion/Reduce Motion safeguards to fix capture artifacts. The existing film’s window-layout chapter is historical: the arranger, window engine and WindowMedia fixtures have been removed. App Shortcuts now owns the retained navigation slot and migrates app-launch bindings only. Do not reintroduce window-manager discovery, frame writes, workspace control, window docks or gesture interception. Existing fullscreen-visibility detection and speech Accessibility handling remain separate. Keep external window managers such as OmniWM independent. See docs/APP_SHORTCUTS.md and docs/MEDIA.md. Keep the 20-second sharing film separate. Preserve Zera v2 branding and 2.0.0 numeric version.
