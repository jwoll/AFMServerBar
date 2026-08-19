# FMServerBar Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Produce a signed, notarized, stapled `.dmg` of FMServerBar that opens with no Gatekeeper warning on any Mac.

**Architecture:** Upgrade `Info.plist` (real bundle ID, version, icon, Apple-Events usage string); add a hardened-runtime `entitlements` file; generate a `.icns` app icon; add a single parameterized `package.sh` that does build → Developer-ID sign → notarize → staple → dmg → sign/notarize/staple-dmg. Keep `build-app.sh` for local dev.

**Tech Stack:** bash, `codesign`, `xcrun notarytool`/`stapler`, `hdiutil`, `iconutil`, Swift (icon render), SwiftPM.

**Note on verification:** Packaging steps can't be unit-tested. Where the plan says "verify," run the exact command and confirm the stated output. Tasks 1–4 are buildable/verifiable locally without an Apple account. Task 5 (notarization) requires the user's Developer ID cert + keychain profile and is run by the user — the plan makes `package.sh` do it in one command but does not execute the network round-trip in-session.

---

## File Structure

```
~/FMServerBar/
├── Info.plist                    (MODIFY — Task 1)
├── FMServerBar.entitlements      (CREATE — Task 2)
├── scripts/make-icns.sh          (CREATE — Task 3)
├── Resources/AppIcon.icns        (GENERATED, committed — Task 3)
├── package.sh                    (CREATE — Task 4 assembles+signs; Task 5 adds notarize/dmg)
├── build-app.sh                  (UNCHANGED)
└── docs/superpowers/RELEASING.md (CREATE — Task 6)
```

---

## Task 1: Upgrade Info.plist

**Files:**
- Modify: `~/FMServerBar/Info.plist`

- [ ] **Step 1: Replace Info.plist with the release metadata**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>FMServerBar</string>
    <key>CFBundleIdentifier</key><string>com.veritysystems.fmserverbar</string>
    <key>CFBundleName</key><string>FM Server</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>FM Server uses Terminal to run the Foundation Models server with Private Cloud Compute access.</string>
</dict>
</plist>
```

- [ ] **Step 2: Verify it's valid plist**

Run: `plutil -lint ~/FMServerBar/Info.plist`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
cd ~/FMServerBar && git add Info.plist && git -c user.name='Claude' -c user.email='claude@local' commit -m "chore: release metadata in Info.plist (bundle id, version, icon, apple-events usage)"
```

---

## Task 2: Hardened-runtime entitlements

**Files:**
- Create: `~/FMServerBar/FMServerBar.entitlements`

- [ ] **Step 1: Create the entitlements file**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Allows sending Apple Events to Terminal.app for the PCC launch path.
         Without this, hardened-runtime denies the osascript-driven control. -->
    <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
```

- [ ] **Step 2: Verify it's valid plist**

Run: `plutil -lint ~/FMServerBar/FMServerBar.entitlements`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
cd ~/FMServerBar && git add FMServerBar.entitlements && git -c user.name='Claude' -c user.email='claude@local' commit -m "feat: hardened-runtime entitlements (apple-events for PCC/Terminal)"
```

---

## Task 3: Generate the .icns app icon

**Files:**
- Create: `~/FMServerBar/scripts/make-icns.sh`
- Generated/committed: `~/FMServerBar/Resources/AppIcon.icns`

- [ ] **Step 1: Create `scripts/make-icns.sh`**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFT=$(mktemp /tmp/mkicon.XXXX.swift)
cat > "$SWIFT" <<'EOF'
import AppKit
// Render the brand icon: green disc + white brain.fill, at one size.
func render(_ px: CGFloat, to url: URL) {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    NSColor.systemGreen.setFill()
    NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: px, height: px)).fill()
    let brainPt = px * 0.72
    let cfg = NSImage.SymbolConfiguration(pointSize: brainPt, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let base = NSImage(systemSymbolName: "brain.fill", accessibilityDescription: nil),
       let brain = base.withSymbolConfiguration(cfg) {
        brain.isTemplate = false
        let bs = brain.size, s = min(brainPt/bs.width, brainPt/bs.height)
        let w = bs.width*s, h = bs.height*s
        brain.draw(in: NSRect(x: (px-w)/2, y: (px-h)/2, width: w, height: h))
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    // Force exact pixel dimensions
    rep.size = NSSize(width: px, height: px)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
// iconset sizes: name -> pixel size
let sizes: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    render(px, to: dir.appendingPathComponent("\(name).png"))
}
print("rendered \(sizes.count) pngs")
EOF
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
swift "$SWIFT" "$ICONSET"
mkdir -p Resources
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -f "$SWIFT"
echo "Wrote Resources/AppIcon.icns"
```

- [ ] **Step 2: Make executable and generate the icon**

Run:
```bash
cd ~/FMServerBar && chmod +x scripts/make-icns.sh && ./scripts/make-icns.sh
```
Expected: `Wrote Resources/AppIcon.icns` and no errors.

- [ ] **Step 3: Verify the icns is valid and multi-size**

Run: `file ~/FMServerBar/Resources/AppIcon.icns && iconutil -l ~/FMServerBar/Resources/AppIcon.icns 2>/dev/null | head; sips -g pixelWidth ~/FMServerBar/Resources/AppIcon.icns`
Expected: identified as "Mac OS X icon" and a pixel width reported (e.g. 1024). (If `iconutil -l` errors, that's fine; the `file` + `sips` checks are the authoritative ones.)

- [ ] **Step 4: Preview it (controller will show the user)**

Run: `open ~/FMServerBar/Resources/AppIcon.icns`
Expected: Preview shows a green circle with a white brain.

- [ ] **Step 5: Commit**

```bash
cd ~/FMServerBar && git add scripts/make-icns.sh Resources/AppIcon.icns && git -c user.name='Claude' -c user.email='claude@local' commit -m "feat: generate brain-in-circle .icns app icon"
```

---

## Task 4: package.sh — build, assemble, sign (local-verifiable portion)

**Files:**
- Create: `~/FMServerBar/package.sh`

This task builds everything through the **signing** step, which is verifiable locally. Notarization/dmg is added in Task 5. Split this way so the signing half can be validated before requiring an Apple account.

- [ ] **Step 1: Create `package.sh` (through signing + verify)**

```bash
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
# Inject VERSION into a copy of Info.plist
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
```

- [ ] **Step 2: Make executable**

Run: `cd ~/FMServerBar && chmod +x package.sh`

- [ ] **Step 3: Dry-run the buildable portion with an AD-HOC identity to prove the assembly + codesign wiring works WITHOUT a Developer ID cert**

Run:
```bash
cd ~/FMServerBar && SIGNING_IDENTITY="-" ./package.sh
```
Expected: steps 1–4 run; assembly succeeds; `codesign` with `-` (ad-hoc) succeeds; `codesign --verify --strict` passes. (`spctl` will say "rejected" — expected for ad-hoc/un-notarized; the script prints the NOTE.) This proves the pipeline's assembly + entitlements + codesign invocation is correct before a real cert is involved.

- [ ] **Step 4: Confirm the app runs and the icon/entitlements took**

Run:
```bash
cd ~/FMServerBar && codesign -d --entitlements - FMServerBar.app 2>/dev/null | grep -q "apple-events" && echo "entitlement present" || echo "MISSING entitlement"
plutil -extract CFBundleIdentifier raw FMServerBar.app/Contents/Info.plist
```
Expected: `entitlement present` and `com.veritysystems.fmserverbar`.

- [ ] **Step 5: Commit**

```bash
cd ~/FMServerBar && git add package.sh && git -c user.name='Claude' -c user.email='claude@local' commit -m "feat: package.sh build+assemble+sign (Developer ID, hardened runtime)"
```

---

## Task 5: package.sh — notarize, staple, dmg

**Files:**
- Modify: `~/FMServerBar/package.sh`

Extends Task 4's script with the network-dependent steps. These require a real Developer ID cert + keychain profile, so the controller does NOT run the notarization round-trip in-session — it verifies the script is syntactically sound and the dmg-assembly logic works with a locally-signed app.

- [ ] **Step 1: Replace the tail of package.sh (from the final echo onward) with notarize/staple/dmg**

Replace the line `echo "Signed $APP ..."` at the end of `package.sh` with:

```bash
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
```

- [ ] **Step 2: Verify script syntax (does not execute network steps)**

Run: `bash -n ~/FMServerBar/package.sh && echo "syntax OK"`
Expected: `syntax OK` (no parse errors).

- [ ] **Step 3: Verify the dmg-assembly logic in isolation with the locally ad-hoc-signed app from Task 4**

Run:
```bash
cd ~/FMServerBar
# app already built+signed ad-hoc from Task 4; test only the dmg packaging commands:
rm -rf dmgroot FMServerBar-test.dmg
mkdir dmgroot && cp -R FMServerBar.app dmgroot/ && ln -s /Applications dmgroot/Applications
hdiutil create -volname "FM Server" -srcfolder dmgroot -ov -format UDZO FMServerBar-test.dmg
rm -rf dmgroot
hdiutil verify FMServerBar-test.dmg && echo "dmg builds OK"
rm -f FMServerBar-test.dmg
```
Expected: `dmg builds OK` — proves the `hdiutil` packaging works; the real dmg (with a notarized app) is produced when the user runs the full `package.sh` with their cert.

- [ ] **Step 4: Commit**

```bash
cd ~/FMServerBar && git add package.sh && git -c user.name='Claude' -c user.email='claude@local' commit -m "feat: package.sh notarize + staple + dmg steps"
```

---

## Task 6: RELEASING.md docs

**Files:**
- Create: `~/FMServerBar/docs/superpowers/RELEASING.md`

- [ ] **Step 1: Write the release doc**

```markdown
# Releasing FMServerBar

Produces a signed, notarized `.dmg` that opens with no Gatekeeper warning.

## One-time setup

1. **Apple Developer Program** membership ($99/yr).
2. **Create a "Developer ID Application" certificate** (Xcode → Settings → Accounts → Manage Certificates → +, or developer.apple.com). Note: `Apple Development` certs do NOT work for distribution.
   Confirm it's installed: `security find-identity -v -p codesigning | grep "Developer ID Application"`
3. **App-specific password** for your Apple ID (appleid.apple.com → Sign-In & Security → App-Specific Passwords).
4. **Store notary credentials** in a keychain profile (once):
   ```
   xcrun notarytool store-credentials "FMServerBar" \
       --apple-id "you@example.com" \
       --team-id "<VERITY_SYSTEMS_TEAM_ID>" \
       --password "<app-specific-password>"
   ```

## Per release

1. Bump `VERSION` at the top of `package.sh` (and `CFBundleVersion` in `Info.plist` if desired).
2. Set the signing identity/team if not default:
   ```
   SIGNING_IDENTITY="Developer ID Application: Verity Systems LLC (TEAMID)" \
   TEAM_ID="TEAMID" NOTARY_PROFILE="FMServerBar" VERSION="0.1.0" \
   ./package.sh
   ```
3. Wait for the two notarization round-trips (~1–5 min each).
4. Distribute the resulting `FMServerBar-<version>.dmg`.

## Regenerating the icon

`./scripts/make-icns.sh` regenerates `Resources/AppIcon.icns` (green disc + white brain).

## Notes

- **First-run PCC prompt:** the first time a user enables PCC, macOS shows "FM Server wants to control Terminal." This is expected automation consent (driven by `NSAppleEventsUsageDescription`); the user clicks OK once.
- **Local dev builds:** use `./build-app.sh` (ad-hoc signed, no notarization) for quick iteration — not for distribution.
- **Verify a built dmg:** `spctl -a -vvv -t install FMServerBar-<version>.dmg` should say `source=Notarized Developer ID`.
```

- [ ] **Step 2: Verify it renders (no broken fences)**

Run: `grep -c '```' ~/FMServerBar/docs/superpowers/RELEASING.md`
Expected: an even number (fences balanced).

- [ ] **Step 3: Commit**

```bash
cd ~/FMServerBar && git add docs/superpowers/RELEASING.md && git -c user.name='Claude' -c user.email='claude@local' commit -m "docs: RELEASING.md (Developer ID setup + per-release steps)"
```

---

## Task 7: README + final local verification

**Files:**
- Modify: `~/FMServerBar/README.md`

- [ ] **Step 1: Add an "Install / Download" section near the top of README.md**

Insert after the intro paragraph (before "## Build & run"):

```markdown
## Install

Download `FMServerBar-<version>.dmg` from the releases, open it, and drag **FM Server** to Applications. The app is signed with a Developer ID and notarized by Apple, so it opens without security warnings.

The first time you enable PCC, macOS will ask permission for FM Server to control Terminal — click OK (this is required for Private Cloud Compute).

For building from source, see below. For cutting a release, see `docs/superpowers/RELEASING.md`.
```

- [ ] **Step 2: Verify README fences balanced**

Run: `grep -c '```' ~/FMServerBar/README.md`
Expected: even number.

- [ ] **Step 3: Full local dry-run of the buildable pipeline (ad-hoc), end to end**

Run:
```bash
cd ~/FMServerBar && SIGNING_IDENTITY="-" bash -c '
set -e
swift build -c release
rm -rf FMServerBar.app
mkdir -p FMServerBar.app/Contents/MacOS FMServerBar.app/Contents/Resources
cp .build/release/FMServerBar FMServerBar.app/Contents/MacOS/FMServerBar
cp Info.plist FMServerBar.app/Contents/Info.plist
cp Resources/AppIcon.icns FMServerBar.app/Contents/Resources/AppIcon.icns
codesign --force --options runtime --entitlements FMServerBar.entitlements --sign - --timestamp=none FMServerBar.app
codesign --verify --strict FMServerBar.app && echo "VERIFY OK"
'
```
Expected: `VERIFY OK` — the full assemble+entitlements+hardened-runtime+codesign chain works with an ad-hoc identity, confirming everything is correct except the (user-supplied) Developer ID + notarization.

- [ ] **Step 4: Launch the packaged app and confirm the app icon + it runs**

Run:
```bash
cd ~/FMServerBar && pkill -9 -f "FMServerBar.app" 2>/dev/null; pkill -f "fm serve" 2>/dev/null; sleep 1
open FMServerBar.app; sleep 4
pgrep -f "FMServerBar.app/Contents/MacOS" >/dev/null && echo "app launched" || echo "app FAILED to launch"
pkill -9 -f "FMServerBar.app" 2>/dev/null; pkill -f "fm serve" 2>/dev/null
```
Expected: `app launched` (and its Dock/Finder icon is the brain-in-circle; the hardened-runtime build runs fine locally).

- [ ] **Step 5: Commit**

```bash
cd ~/FMServerBar && git add README.md && git -c user.name='Claude' -c user.email='claude@local' commit -m "docs: README install section"
```

---

## Notes for the implementer

- **Do not run the real notarization** (`notarytool submit`) — it needs the user's Developer ID cert + keychain profile that aren't present. Verify with ad-hoc signing (`SIGNING_IDENTITY="-"`) and `bash -n` syntax checks instead. The user runs the real `./package.sh` per RELEASING.md.
- **Ad-hoc caveat:** `--timestamp` requires network + a real cert; when dry-running with `SIGNING_IDENTITY="-"` use `--timestamp=none` (as in Task 7 Step 3) to avoid a network call. The committed `package.sh` keeps `--timestamp` (correct for the real Developer ID path).
- **`spctl` will report "rejected" for ad-hoc/un-notarized builds** — that's expected and not a failure of the signing step; only the real notarized dmg passes `spctl`.
- **Hardened runtime + entitlements are the risk for PCC** — after the user does a real notarized build, they must verify PCC still works (enable it, check `pcc: available`). Called out in RELEASING.md.
- Keep `build-app.sh` unchanged; it's the fast local-dev path.
