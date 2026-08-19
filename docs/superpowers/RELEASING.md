# Releasing FMServerBar

Produces a signed, notarized `.dmg` that opens with no Gatekeeper warning on any Mac.

## One-time setup

1. **Apple Developer Program** membership ($99/yr).
2. **Create a "Developer ID Application" certificate** (Xcode → Settings → Accounts →
   Manage Certificates → +, or developer.apple.com). Note: `Apple Development` certs do
   NOT work for distribution — you need a **Developer ID Application** cert.
   Confirm it's installed:
   ```
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```
3. **App-specific password** for your Apple ID (appleid.apple.com → Sign-In & Security →
   App-Specific Passwords).
4. **Store notary credentials** in a keychain profile named `FMServerBar` (once):
   ```
   xcrun notarytool store-credentials "FMServerBar" \
       --apple-id "you@example.com" \
       --team-id "<VERITY_SYSTEMS_TEAM_ID>" \
       --password "<app-specific-password>"
   ```
   (`package.sh` references this profile via `--keychain-profile`; no secrets live in
   the script or repo.)

## Per release

1. Bump `VERSION` when you invoke `package.sh` (and optionally `CFBundleVersion` in
   `Info.plist`).
2. Run the pipeline, overriding the signing identity to include your team ID in
   parentheses so codesign picks the exact cert:
   ```
   SIGNING_IDENTITY="Developer ID Application: Verity Systems LLC (TEAMID)" \
   NOTARY_PROFILE="FMServerBar" \
   VERSION="0.1.0" \
   ./package.sh
   ```
3. Wait for the two notarization round-trips (steps 6 and 9; ~1–5 min each). If Apple
   rejects a submission, `package.sh` automatically fetches and prints the notarization
   log so you can see why.
4. Distribute the resulting `FMServerBar-<version>.dmg`.

## Regenerating the app icon

`./scripts/make-icns.sh` regenerates `Resources/AppIcon.icns` (green disc + white brain).
Only re-run and commit when the icon **design** changes — the output isn't bit-for-bit
reproducible (embedded PNG metadata), so a rerun shows a tiny git diff even when the icon
is visually identical.

## Notes

- **First-run PCC prompt:** the first time a user enables PCC, macOS shows "FM Server
  wants to control Terminal." This is expected automation consent (driven by
  `NSAppleEventsUsageDescription`); the user clicks OK once. If it breaks after a
  hardened-runtime build, verify the `com.apple.security.automation.apple-events`
  entitlement is present: `codesign -d --entitlements - FMServerBar.app`.
- **Local dev builds:** use `./build-app.sh` (ad-hoc signed, no notarization) for quick
  iteration — not for distribution.
- **Verify a built dmg:** `spctl -a -vvv -t install FMServerBar-<version>.dmg` should
  report `source=Notarized Developer ID`.
- **`--timestamp` needs network:** signing contacts Apple's timestamp server; it will
  fail on an offline/captive-portal machine.
