#!/bin/bash
# Builds Zera.app (universal) into ./dist
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Zera"
BUNDLE_ID="io.github.amsynist.zera"
# Version: $ZERA_VERSION (CI sets it from the tag, e.g. v0.3.0 → 0.3.0), else the latest
# git tag, else 0.1. Build number: $ZERA_BUILD (CI run number), else the commit count.
VERSION="${ZERA_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
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
# Optional: GitHub's mark for the PR screen (download it yourself from github.com/logos).
if [ -f Resources/github-mark.png ]; then cp Resources/github-mark.png "$APP/Contents/Resources/"; fi

echo "==> Rendering icon"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
ICONBUILD="$DIST/iconbuild"
rm -rf "$ICONBUILD"; mkdir -p "$ICONBUILD"
cp Tools/MakeIcon.swift "$ICONBUILD/main.swift"
cp Sources/Zera/ZeraView.swift Sources/Zera/Sprites.swift "$ICONBUILD/"
swiftc -O -o "$ICONBUILD/makeicon" "$ICONBUILD/main.swift" "$ICONBUILD/ZeraView.swift" "$ICONBUILD/Sprites.swift"
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
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSCalendarsUsageDescription</key><string>Zera shows your events for the next two weeks next to your reminders, warns you before meetings, and adds events to a calendar only when you choose one. Calendar data stays on your Mac.</string>
  <key>NSAppleEventsUsageDescription</key><string>Only for the explicit “Open Claude” action when the Claude app is not installed: Zera opens a Terminal window running claude. Summarize, Explain and Ask never use this.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Zera shows your events for the next two weeks next to your reminders, warns you before meetings, and adds events to a calendar only when you choose one. Calendar data stays on your Mac.</string>
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
# runtime + entitlements, ready for notarization); otherwise ad-hoc for local use.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "==> Signing with $CODESIGN_IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --entitlements Resources/Zera.entitlements \
    --sign "$CODESIGN_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "==> Signing (ad-hoc)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "    codesign skipped"
fi

rm -f "$DIST/icon_1024.png"
echo "==> Done: $(pwd)/$APP (version $VERSION, build $BUILD)"
