# FMServerBar

A macOS menu-bar app that turns Apple's Foundation Models into a local
OpenAI-compatible endpoint with one click, by launching and supervising
Apple's built-in `fm serve` (`/usr/bin/fm`).

It is a thin wrapper: `fm serve` is the actual server. FMServerBar launches it
as a subprocess, polls `/health`, and shows status in the menu bar.

## Install

Download `FMServerBar-<version>.dmg` from the releases, open it, and drag
**FM Server** to Applications. The app is signed with a Developer ID and
notarized by Apple, so it opens without security warnings.

The first time you enable PCC, macOS will ask permission for FM Server to
control Terminal — click OK (this is required for Private Cloud Compute).

For building from source, see below. For cutting a release, see
`docs/superpowers/RELEASING.md`.

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
- **On-device ↔ PCC toggle** ("Enable PCC (via Terminal)"): switches between the
  on-device `system` model and Private Cloud Compute. See below.
- **Editable port** (default 1976), Apply restarts the server.
- **Copy base URL** button.
- **Per-model status** polled from `/health` every 3s.
- **Launch at Login** toggle (`SMAppService`, off by default; only effective
  from the packaged `.app`).
- **Self-healing port:** if the app crashes/force-quits, its orphaned child is
  reaped on next launch — tracked by PID, so a `fm serve` you started yourself
  is never touched.
- **Clean shutdown on every quit path** (Cmd-Q, menu Quit, `osascript quit`,
  logout) via `NSApplication.willTerminateNotification` — stops the server and,
  in PCC mode, closes its Terminal window.

## On-device vs PCC (the "Enable PCC" toggle)

`fm` gates Private Cloud Compute on **responsible-process attribution**: only a
process whose responsible app is **Terminal.app** may use `pcc`. A GUI app's
direct subprocess cannot (it returns *"Private Cloud Compute is not available in
this context"*).

The app handles both:

- **On-device (default):** spawns `fm serve` directly as a background subprocess.
  `system` works; `pcc` shows unavailable. No window.
- **Enable PCC (via Terminal):** launches `fm serve` *inside Terminal.app* (via
  AppleScript) so Terminal is the responsible process — **both `system` and
  `pcc` work** — then minimizes just that window (other Terminal windows are
  untouched). Switching back stops that server and closes its window.

Toggling stops the current server before starting the new mode. A brief (~1s)
Terminal flash occurs when enabling PCC; the window then minimizes to the Dock.
It cannot be fully headless — Terminal must stay the responsible process.

## Architecture

- `HealthPoller.swift` — `Health`/`ModelHealth` types + `poll(port:)`.
- `ServerController.swift` — `fm serve` subprocess lifecycle + own-orphan reap.
- `AppState.swift` — `@MainActor` coordinator (controller + poller + login item).
- `FMServerBarApp.swift` — `@main` `MenuBarExtra` + menu view.

Design + plan: `docs/superpowers/`.
