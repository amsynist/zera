#!/bin/bash
# Packages dist/Zera.app for a release: notarizes and staples it when Apple credentials are
# set, then writes Zera-<version>.dmg, Zera-<version>.zip and SHA256SUMS.txt into dist/.
#
#   ZERA_VERSION        e.g. 0.3.0 (required — CI sets it from the tag)
#   APPLE_ID            Apple ID email           ┐
#   APPLE_TEAM_ID       10-character team id     ├ all three → notarize + staple
#   APPLE_APP_PASSWORD  app-specific password    ┘ (missing → unsigned/ad-hoc release)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${ZERA_VERSION:?set ZERA_VERSION}"
APP="dist/Zera.app"
ZIP="dist/Zera-$VERSION.zip"
DMG="dist/Zera-$VERSION.dmg"
[ -d "$APP" ] || { echo "error: $APP not found — run ./build.sh first" >&2; exit 1; }

notarize() {  # $1 = file to submit
  xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" --wait --timeout 30m
}

can_notarize=false
if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
  can_notarize=true
fi

if $can_notarize; then
  echo "==> Notarizing the app"
  ditto -c -k --keepParent "$APP" dist/notarize.zip
  notarize dist/notarize.zip
  rm -f dist/notarize.zip
  xcrun stapler staple "$APP"
else
  echo "==> Skipping notarization (no Apple credentials) — users will right-click → Open once"
fi

echo "==> Zipping"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Building the disk image"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Zera $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
fi
if $can_notarize; then
  echo "==> Notarizing the disk image"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi

echo "==> Checksums"
(cd dist && shasum -a 256 "Zera-$VERSION.dmg" "Zera-$VERSION.zip" > SHA256SUMS.txt && cat SHA256SUMS.txt)
echo "==> Ready: $DMG, $ZIP"
