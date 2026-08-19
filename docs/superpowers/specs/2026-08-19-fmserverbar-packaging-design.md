# FMServerBar — Distribution Packaging (Developer ID + Notarized DMG)

**Date:** 2026-08-19
**Status:** Approved design, ready for implementation plan
**Goal:** Turn FMServerBar into a signed, notarized `.dmg` that any macOS user can download and open with a normal double-click (no Gatekeeper warnings).

## Why this is needed

The current `build-app.sh` ad-hoc signs (`codesign -s -`). That runs on the build machine but macOS Gatekeeper blocks it on any other Mac ("damaged / can't be opened"). Public distribution requires: **Developer ID signing → notarization → stapling**, packaged as a `.dmg`.

## Confirmed decisions

- **Audience:** general public. **Developer ID** signing + notarization (user has / will get the account).
- **Bundle ID:** `com.veritysystems.fmserverbar` (matches the "Verity Systems LLC" identity on the machine).
- **Format:** `.dmg`, drag-to-Applications.
- **Notary auth:** keychain profile via `xcrun notarytool store-credentials` (no secrets in script/repo).
- **App icon:** generate a `.icns` from the brain-in-circle design (green disc + white brain), static green (not a live status indicator).
- **Approach:** a single `package.sh` (zero new dependencies); keep `build-app.sh` for local dev.

## Environment findings (verified 2026-08-19)

- `notarytool` present (via Xcode 26.6).
- Signing identities on machine: `Apple Development` (John Woll) + `Apple Configurator` certs — **no "Developer ID Application" cert yet**. User must create one in their Apple Developer account before notarization can run.
- Two teams visible (John Woll); use the **Verity Systems LLC** team for `com.veritysystems.*`.
- No git remote (dmg is a standalone file; hosting is out of scope).

## Files

```
~/FMServerBar/
├── Info.plist                    (UPDATED)
├── FMServerBar.entitlements      (NEW)
├── package.sh                    (NEW — full release pipeline)
├── build-app.sh                  (UNCHANGED — quick ad-hoc dev build)
├── scripts/make-icns.sh          (NEW — generates the .icns)
├── Resources/AppIcon.icns        (NEW — committed generated icon)
└── docs/superpowers/RELEASING.md (NEW — setup + per-release steps)
```

### Info.plist updates
- `CFBundleIdentifier` → `com.veritysystems.fmserverbar`
- `CFBundleShortVersionString` (marketing, e.g. `0.1.0`) + `CFBundleVersion` (build, e.g. `1`)
- `CFBundleIconFile` → `AppIcon`
- **`NSAppleEventsUsageDescription`** → "FM Server uses Terminal to run the Foundation Models server with Private Cloud Compute access." (REQUIRED — hardened runtime blocks Apple Events without it)
- Keep `LSUIElement=true`, `LSMinimumSystemVersion=26.0`

## Entitlements & hardened runtime

`FMServerBar.entitlements`:
- `com.apple.security.automation.apple-events` = `true` — allows sending Apple Events to Terminal.app (the PCC launch path). Without this, the `osascript`-driven Terminal control is denied at runtime even after notarization.
- **No App Sandbox** — the app spawns `/usr/bin/fm`, runs `pkill`/`pgrep`/`osascript`, and binds a local port; the sandbox would block these. Developer ID + notarization does NOT require sandboxing (only the Mac App Store does).
- Omit `cs.allow-unsigned-executable-memory` etc. unless a notarization/runtime error specifically demands it.

**Expected behavior:** first time PCC is enabled, macOS shows a one-time "FM Server wants to control Terminal" consent prompt (driven by `NSAppleEventsUsageDescription`). This is normal automation consent, not a bug; documented in RELEASING.md.

## `package.sh` pipeline

Parameterized at top:
```bash
SIGNING_IDENTITY="Developer ID Application: Verity Systems LLC (TEAMID)"
TEAM_ID="…"                    # Verity Systems team id
NOTARY_PROFILE="FMServerBar"   # keychain profile from store-credentials
VERSION="0.1.0"                # build number auto-derived/bumped
```

Steps (each fails loudly under `set -euo pipefail`, with progress echoes):
1. `swift build -c release`
2. Assemble `FMServerBar.app` — binary + Info.plist (VERSION injected) + `Resources/AppIcon.icns`.
3. Sign: `codesign --force --options runtime --entitlements FMServerBar.entitlements --sign "$SIGNING_IDENTITY" --timestamp FMServerBar.app`
4. Verify: `codesign --verify --strict --verbose=2` + `spctl -a -vv` (catch errors before notarization).
5. Zip: `ditto -c -k --keepParent FMServerBar.app FMServerBar.zip`
6. Notarize: `xcrun notarytool submit FMServerBar.zip --keychain-profile "$NOTARY_PROFILE" --wait` (on rejection, fetch+print the log).
7. Staple: `xcrun stapler staple FMServerBar.app`
8. Build dmg: temp folder with stapled `.app` + `Applications` symlink → `hdiutil create` compressed → `FMServerBar-<version>.dmg`.
9. Sign + notarize + staple the `.dmg` (Gatekeeper checks the dmg too).
10. Final `spctl` gatecheck + print output path.

Steps 6 and 9 each make a network round-trip to Apple (~1–5 min); the script waits and echoes progress. Requires network + the keychain profile.

## Icon generation

`scripts/make-icns.sh`:
- Swift snippet renders the brain-in-circle (green disc + white `brain.fill`) at iconset sizes 16/32/128/256/512 @1x and @2x into `AppIcon.iconset`, then `iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns`.
- App icon is **static green** (brand), distinct from the live-color menu-bar status icon.
- `.icns` is committed so `package.sh` doesn't regenerate each release. Preview before committing.

## Docs — `RELEASING.md`

- **One-time:** create "Developer ID Application" cert; `xcrun notarytool store-credentials "FMServerBar"` (Apple ID + app-specific password + Verity Systems Team ID).
- **Per release:** bump `VERSION`, run `./package.sh`, wait for notarization, distribute the `.dmg`.
- Note the first-run Terminal-automation consent prompt.

## Testing / verification

- `codesign --verify --strict --verbose=2 FMServerBar.app` → valid.
- `spctl -a -vvv -t install FMServerBar.dmg` → "accepted, source=Notarized Developer ID".
- `xcrun stapler validate` on app and dmg → success.
- Quarantine simulation: `xattr -w com.apple.quarantine "0081;...;;" FMServerBar.app` then open → no Gatekeeper warning.
- Post-hardened-runtime PCC check: launch packaged app, enable PCC, confirm `pcc: available` (the apple-events entitlement is the risk being verified).

## Honest limitations / boundaries

- Notarize/staple steps (6, 7, 9) require the user's Apple credentials + a Developer ID Application cert **not yet present** on the machine. Everything up to signing can be built and dry-run locally; the real notarization round-trips run on the user's machine with their account.
- The Terminal window for PCC still appears (minimized) — unchanged by packaging; hardened runtime doesn't alter that.

## Out of scope (YAGNI)

- Hosting/GitHub release automation (dmg is a standalone artifact; publish happens after packaging is done).
- Homebrew cask (can point at the dmg later).
- Auto-update (Sparkle etc.).
- Fancy dmg background art (plain drag-to-Applications layout).
