# FM Server Bar

A macOS menu-bar app that gives you a one-click local AI endpoint using Apple's built-in Foundation Models — no API key, no cloud, no setup.

It wraps Apple's `fm serve` CLI, auto-starts it at launch, and exposes an OpenAI-compatible endpoint at `http://127.0.0.1:1976/v1`. Plug it into any tool that accepts a custom OpenAI base URL: Cursor, Continue, FluidVoice, the OpenAI SDK, or anything else.

## Requirements

- macOS 26 (Tahoe) or later
- Apple Foundation Models (`/usr/bin/fm`) — ships with macOS 26

## Install

1. Download `FMServerBar-<version>.dmg` from [Releases](https://github.com/jwoll/AFMServerBar/releases)
2. Open the dmg and drag **FM Server** to Applications
3. Launch it — the server starts automatically and a status icon appears in your menu bar

Signed with a Developer ID and notarized by Apple, so it opens without any security warning.

## Use with any OpenAI client

| Setting | Value |
|---|---|
| Base URL | `http://127.0.0.1:1976/v1` |
| API key | any value (ignored) |
| Models | `system` (on-device) · `pcc` (Private Cloud Compute) |

## Features

- **Always-on endpoint** — auto-starts `fm serve` on launch; Start/Stop toggle in the menu
- **On-device or PCC** — toggle between the local `system` model and Apple's privacy-preserving Private Cloud Compute; see [how PCC works](#on-device-vs-pcc) below
- **Live status** — menu-bar icon turns green (healthy), yellow (degraded), or red (stopped); per-model health shown in the menu
- **Editable port** — default 1976, change and Apply restarts the server
- **Copy base URL** — one click to copy the endpoint for pasting into a client
- **Launch at Login** — optional, off by default
- **Self-healing** — if the app crashes, it reaps its own orphaned `fm serve` process on next launch without touching any `fm serve` you started yourself
- **Clean shutdown** — stops the server on every quit path (Cmd-Q, menu Quit, logout)

## On-device vs PCC

Apple gates Private Cloud Compute on the responsible process being Terminal.app. A GUI app's subprocess cannot use PCC directly.

When you enable the **"Enable PCC (via Terminal)"** toggle, FM Server Bar launches `fm serve` inside Terminal.app via AppleScript, then minimizes that window. Terminal becomes the responsible process and both `system` and `pcc` work. Switching back stops that server and closes the window.

The first time you enable PCC, macOS will ask permission for FM Server to control Terminal — click OK. This prompt appears once.

## Build from source

```
git clone https://github.com/jwoll/AFMServerBar.git
cd AFMServerBar
./build-app.sh    # builds + ad-hoc signs FMServerBar.app
open FMServerBar.app
```

## Architecture

| File | Role |
|---|---|
| `HealthPoller.swift` | `Health`/`ModelHealth` types + `poll(port:)` |
| `ServerController.swift` | `fm serve` subprocess lifecycle, orphan reap |
| `AppState.swift` | `@MainActor` coordinator — controller, poller, login item |
| `FMServerBarApp.swift` | `@main` `MenuBarExtra` + menu view |
