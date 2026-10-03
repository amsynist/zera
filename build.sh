#!/bin/bash
# Builds Zera.app (universal) into ./dist
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Zera"
BUNDLE_ID="io.github.amsynist.zera"
VERSION="0.1"
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
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSCalendarsUsageDescription</key><string>Zera reads today's events so she can warn you 15 minutes before a meeting.</string>
  <key>NSAppleEventsUsageDescription</key><string>Only for the explicit “Open Claude” action when the Claude app is not installed: Zera opens a Terminal window running claude. Summarize, Explain and Ask never use this.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Zera reads today's events so she can warn you 15 minutes before a meeting.</string>
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

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "    codesign skipped"

rm -f "$DIST/icon_1024.png"
echo "==> Done: $(pwd)/$APP"
