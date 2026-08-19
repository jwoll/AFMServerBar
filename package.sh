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

echo "Signed $APP (version $VERSION). Notarization + dmg steps run in Task 5 / full package.sh."
