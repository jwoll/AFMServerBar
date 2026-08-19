#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# ---- Configuration (edit these for your account) ----
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Verity Systems LLC}"
TEAM_ID="${TEAM_ID:-}"                       # e.g. 382AE2E2...
NOTARY_PROFILE="${NOTARY_PROFILE:-FMServerBar}"
VERSION="${VERSION:-0.1.0}"
APP="FMServerBar.app"
DMG="FMServerBar-${VERSION}.dmg"
# ------------------------------------------------------

echo "==> [1/10] swift build -c release"
swift build -c release

echo "==> [2/10] assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FMServerBar "$APP/Contents/MacOS/FMServerBar"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "==> [3/10] codesign (Developer ID + hardened runtime + entitlements)"
codesign --force --options runtime \
    --entitlements FMServerBar.entitlements \
    --sign "$SIGNING_IDENTITY" --timestamp \
    "$APP"

echo "==> [4/10] verify signature"
codesign --verify --strict --verbose=2 "$APP"
spctl -a -vv "$APP" || echo "NOTE: spctl will say 'rejected' until notarization+staple (Task 5). Signature itself is what matters here."

echo "==> [5/10] zip for notarization"
rm -f FMServerBar.zip
ditto -c -k --keepParent "$APP" FMServerBar.zip

echo "==> [6/10] notarize app (waits for Apple; ~1-5 min)"
xcrun notarytool submit FMServerBar.zip \
    --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> [7/10] staple app"
xcrun stapler staple "$APP"

echo "==> [8/10] build dmg"
rm -rf dmgroot "$DMG"
mkdir dmgroot
cp -R "$APP" dmgroot/
ln -s /Applications dmgroot/Applications
hdiutil create -volname "FM Server" -srcfolder dmgroot -ov -format UDZO "$DMG"
rm -rf dmgroot

echo "==> [9/10] sign, notarize, staple the dmg"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> [10/10] final gatecheck"
spctl -a -vvv -t install "$DMG"
echo "DONE: $DMG"
