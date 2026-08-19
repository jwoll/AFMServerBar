#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="FMServerBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/FMServerBar "$APP/Contents/MacOS/FMServerBar"
cp Info.plist "$APP/Contents/Info.plist"
codesign -s - --force --deep "$APP"
echo "Built $APP — run: open $APP"
