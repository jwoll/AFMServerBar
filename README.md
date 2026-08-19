# FMServerBar

A macOS menu-bar app that turns Apple's Foundation Models into a local
OpenAI-compatible endpoint with one click, by launching and supervising
Apple's built-in `fm serve` (`/usr/bin/fm`).

It is a thin wrapper: `fm serve` is the actual server. FMServerBar launches it
as a subprocess, polls `/health`, and shows status in the menu bar.

## Build & run

```
cd ~/FMServerBar
./build-app.sh          # builds + ad-hoc signs FMServerBar.app
open FMServerBar.app     # menu-bar icon appears; server auto-starts on port 1976
```

The app is an agent app (`LSUIElement`) — no Dock icon. A status-tinted brain
symbol shows in the menu bar: green = running + on-device model available,
yellow = running but a model not ready, red = stopped/failed.

## Use with FluidVoice (or any OpenAI client)

- Base URL: `http://127.0.0.1:1976/v1`
- API key: any value (ignored; localhost only)
- Refresh models → pick `system` (on-device) or `pcc` (Private Cloud Compute)

## Features

- **Auto-start** on launch (from `AppState.init()`), Start/Stop toggle.
- **Editable port** (default 1976), Apply restarts the server.
- **Copy base URL** button.
- **Per-model status** polled from `/health` every 3s.
- **Launch at Login** toggle (`SMAppService`, off by default; only effective
  from the packaged `.app`).
- **Self-healing port:** if the app crashes/force-quits, its orphaned child is
  reaped on next launch — tracked by PID, so a `fm serve` you started yourself
  (e.g. in Terminal) is never touched.

## Known limitation: PCC needs Terminal

Verified empirically: the on-device `system` model works from the app. But
`pcc` (Private Cloud Compute) returns *"Private Cloud Compute is not available
in this context. Please use the Terminal app."* when `fm serve` is launched by
a GUI app. The menu shows this honestly (`pcc: ✗ …`).

If you need PCC, run `fm serve` yourself in **Terminal.app** (on a different
port, or stop the app first):

```
fm serve --port 1976
```

Then point your client at that instead.

## Architecture

- `HealthPoller.swift` — `Health`/`ModelHealth` types + `poll(port:)`.
- `ServerController.swift` — `fm serve` subprocess lifecycle + own-orphan reap.
- `AppState.swift` — `@MainActor` coordinator (controller + poller + login item).
- `FMServerBarApp.swift` — `@main` `MenuBarExtra` + menu view.

Design + plan: `docs/superpowers/`.
