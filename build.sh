#!/bin/bash
# Builds Zera.app (universal) into ./dist
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Zera"
BUNDLE_ID="io.github.amsynist.zera"
# Version: $ZERA_VERSION (CI tag override), else VERSION, latest git tag, then 0.1.
# Build number: $ZERA_BUILD (CI run number), else the commit count.
VERSION="${ZERA_VERSION:-$(cat VERSION 2>/dev/null || git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1}"
BUILD="${ZERA_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> Compiling (arm64 + x86_64)"
if ! swift build -c release --arch arm64 --arch x86_64 >/dev/null 2>&1; then
  echo "    universal build unavailable, falling back to native arch"
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
else
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
fi

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
mkdir -p "$APP/Contents/Resources/Sprites"
cp Resources/Sprites/*.png "$APP/Contents/Resources/Sprites/"
mkdir -p "$APP/Contents/Resources/Sounds"
cp Resources/Sounds/*.wav "$APP/Contents/Resources/Sounds/"
cp LICENSE LICENSE-ASSETS.md THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# Optional: GitHub's mark for the PR screen (download it yourself from github.com/logos).
if [ -f Resources/github-mark.png ]; then cp Resources/github-mark.png "$APP/Contents/Resources/"; fi

echo "==> Rendering icon"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
ICONBUILD="$DIST/iconbuild"
rm -rf "$ICONBUILD"; mkdir -p "$ICONBUILD"
cp Tools/MakeIcon.swift "$ICONBUILD/main.swift"
cp Sources/Zera/ZeraView.swift Sources/Zera/Sprites.swift Sources/Zera/ZeraFace.swift Sources/Zera/ZeraAnimationClock.swift "$ICONBUILD/"
swiftc -O -o "$ICONBUILD/makeicon" "$ICONBUILD/main.swift" "$ICONBUILD/ZeraView.swift" "$ICONBUILD/Sprites.swift" "$ICONBUILD/ZeraFace.swift" "$ICONBUILD/ZeraAnimationClock.swift"
"$ICONBUILD/makeicon" "$DIST/icon_1024.png" "$(pwd)/Resources/Sprites" >/dev/null
rm -rf "$ICONBUILD"
for s in 16 32 64 128 256 512; do
  sips -z $s $s "$DIST/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2))
  sips -z $d $d "$DIST/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>Zera</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- Starts without a Dock icon; Zera adds it at launch unless it's turned off in Settings → General. -->
  <key>LSUIElement</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Receive original files from your paired Android phone on the same Wi-Fi or hotspot.</string>
  <key>NSBonjourServices</key><array><string>_androp._tcp</string></array>
  <key>NSCalendarsUsageDescription</key><string>Zera shows your events for the next two weeks next to your reminders, warns you before meetings, and adds events to a calendar only when you choose one. Calendar data stays on your Mac.</string>
  <key>NSAppleEventsUsageDescription</key><string>Zera asks Spotify or Music what is playing to show it on Home with play, pause and skip, and opens a Terminal window running claude for the explicit “Open Claude” action when the Claude app is not installed. Summarize, Explain and Ask never use this.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Only for the weather on Home, if you turn it on: your location fetches the local forecast and is not stored or sent anywhere else.</string>
  <key>NSLocationUsageDescription</key><string>Only for the weather on Home, if you turn it on: your location fetches the local forecast and is not stored or sent anywhere else.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Zera shows your events for the next two weeks next to your reminders, warns you before meetings, and adds events to a calendar only when you choose one. Calendar data stays on your Mac.</string>
  <key>NSMicrophoneUsageDescription</key><string>Only if you turn on voice answers or dictation: Zera listens while a Claude permission card is waiting, or while you hold right Option to dictate. Nothing is recorded or kept.</string>
  <key>NSScreenCaptureUsageDescription</key><string>Only for optional visual window transitions: Zera briefly captures the selected windows and their display background to animate movement. Images stay in memory, are discarded after the transition, and are never saved or uploaded.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Only if you turn on real music bars: Zera reads how loud the sound playing on your Mac is, moment to moment, to move the bars. Nothing is recorded.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Turns your short voice answers (approve, deny, open) and your dictation into text, on this Mac whenever it supports it.</string>
  <!-- "Open With → Zera" puts any file on the Shelf. Alternate rank: Zera never becomes the default app. -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Any File</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.item</string><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Signing: a Developer ID identity when $CODESIGN_IDENTITY is set (release builds — hardened
# runtime + entitlements, ready for notarization); otherwise prefer the stable local identity.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "==> Signing with $CODESIGN_IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --entitlements Resources/Zera.entitlements \
    --sign "$CODESIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
elif [ -x .rea/local-sign.sh ]; then
  # Never silently change an established identity to ad-hoc: TCC approvals would still
  # appear enabled while their stored code requirement rejects the replacement app.
  .rea/local-sign.sh "$APP"
  codesign --verify --deep --strict "$APP"
  echo "==> Signed with the project's stable local identity (permissions survive rebuilds)"
else
  echo "==> Signing (ad-hoc)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "    codesign skipped"
fi

# Local debugging: keep the running app's diagnostics log (modifier keys and states only).
if [ -f "$HOME/Library/Application Support/Zera/diag.log" ]; then
  mkdir -p .rea/diag && cp "$HOME/Library/Application Support/Zera/diag.log" .rea/diag/latest.log
fi
# Diagnostics for the self-test: an app holding Secure Keyboard Entry hides every key from Zera.
SPID=$(ioreg -l -w 0 2>/dev/null | grep -o '"kCGSSessionSecureInputPID"=[0-9]*' | head -1 | grep -o '[0-9]*$' || true)
if [ -n "${SPID:-}" ]; then echo "==> Secure keyboard entry is ON, held by pid $SPID ($(ps -p "$SPID" -o comm= 2>/dev/null))"; else echo "==> Secure keyboard entry: off"; fi
rm -f "$DIST/icon_1024.png"
echo "==> Done: $(pwd)/$APP (version $VERSION, build $BUILD)"
