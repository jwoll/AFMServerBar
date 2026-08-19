# FMServerBar — menu-bar wrapper for `fm serve`

**Date:** 2026-08-19
**Status:** Approved design, ready for implementation plan
**Location:** `~/FMServerBar/`

## Goal

A macOS menu-bar app that turns Apple's built-in Foundation Models server
(`fm serve`) on/off with one click and shows its status — so you don't have to
keep a Terminal window open. It is a **thin wrapper**: it launches `fm serve`
as a subprocess and polls its `/health` endpoint. It does NOT reimplement the
HTTP server (Apple already ships it).

## Why a wrapper (not a reimplementation)

`/usr/bin/fm serve` is a supported OpenAI-compatible Chat Completions server
exposing `GET /health`, `GET /v1/models`, `POST /v1/chat/completions`
(streaming + non-streaming) for models `system` (on-device) and `pcc`
(Private Cloud Compute). A menu-bar app launches/stops it as a subprocess.

### Empirical findings (verified 2026-08-19, from the built app)

- **On-device (`system`) works from the GUI-launched app.** Auto-start fires at
  launch (from `AppState.init()`), `/health` and `/v1/chat/completions` respond.
- **PCC (`pcc`) is gated on responsible-process attribution — it requires
  Terminal.app.** `fm` checks the responsible process (a `TerminalAppearanceProbe`
  class in the binary confirms this); it is NOT a TTY check, NOT a flag/env, NOT
  an entitlement `fm` itself carries. A GUI app's direct subprocess gets
  `503 "Private Cloud Compute is not available in this context. Please use the
  Terminal app."` But launching `fm serve` THROUGH Terminal.app (via
  `osascript ... tell application "Terminal" to do script`) makes Terminal the
  responsible process and PCC works (verified: `pcc: available` + real streamed
  completion). See the PCC-mode feature below.
- **Orphan handling:** a clean **Quit** (button → `shutdown()` → `stop()`)
  terminates the child. A crash / SIGKILL / SIGTERM does NOT (SwiftUI runs no
  reliable cleanup on signals), so the child orphans. This is made self-healing
  by reaping the app's OWN previously-spawned child by tracked PID (persisted to
  UserDefaults `lastChildPID`, verified still an `fm serve` via `ps` before
  killing) at the start of every `start()` — so a user's own `fm serve` is never
  touched.

### PCC mode (Model-context toggle)

A menu toggle **Model context** switches how `fm serve` is launched:
- **On-device (background)** — DEFAULT. `ServerController` spawns `fm serve`
  directly via `Process` (no window). `system` works; `pcc` shows unavailable.
- **Enable PCC (Terminal)** — launches `fm serve` via
  `osascript`→Terminal.app `do script`, making Terminal the responsible process
  so BOTH `system` and `pcc` work. The app then **minimizes just that Terminal
  window** (`set miniaturized of <window> to true` — verified to preserve PCC and
  leave the user's other Terminal windows untouched). A brief (~1s) flash occurs
  before minimize; the window genuinely exists (minimized), because Terminal must
  stay the responsible process — truly headless is impossible.

Toggling: stop the current server first (kill by tracked PID; in Terminal mode
also close its `fm serve` Terminal window), then start in the new mode. The
child PID is tracked in the SAME `lastChildPID` slot regardless of mode, so
stop/reap logic is uniform. Health polling and `statusColor` are unchanged —
`/health` reports real per-mode `pcc` availability. Mode is persisted; default
on-device. Menu shows a caption in PCC mode: "Runs fm serve in a minimized
Terminal window — keep it open."

## Confirmed facts (verified 2026-08-19)

- `fm` binary: `/usr/bin/fm`.
- Default port: **1976** (bare `fm serve`).
- `/health` JSON shape:
  `{"status":"fm serve is running","models":[{"name":"system","available":true},{"name":"pcc","available":true}]}`
  (`reason: String?` present when a model is unavailable).
- PCC reported `available:true` from the Aqua-session server; reported
  unavailable from a sandboxed shell (context-dependent — the reason for the app).

## Scope decisions (confirmed with user)

- **Status source:** poll `GET /health` (~every 3s); show per-model availability.
- **Default port:** **1976** (fm's default; editable in menu).
- **On quit:** terminate the `fm serve` subprocess (no orphan).
- **Startup:** auto-start subprocess on app launch.
- **Launch at Login:** menu checkbox via `SMAppService.mainApp` (macOS 13+),
  **off by default** (explicit opt-in). Registers the `.app` itself as a login
  item — appears in System Settings > General > Login Items. Because the app
  launches in the user's Aqua GUI session, its `fm serve` subprocess keeps the
  context PCC needs (unlike a headless LaunchAgent). Only effective from the
  packaged/signed `.app`, not `swift run`.
- **Packaging:** SwiftPM executable → `LSUIElement` agent `.app`, ad-hoc signed
  (same approach as the earlier design).
- **Icon:** status-tinted SF Symbol (green/yellow/red), non-template `NSImage`.

## Architecture

SwiftPM executable at `~/FMServerBar/`. Menu-bar agent app, no Dock icon.
Four focused source files:

```
~/FMServerBar/
├── Package.swift                    # executable target, macOS 26
├── Info.plist                       # LSUIElement=true
├── build-app.sh                     # bundle .app + ad-hoc codesign
└── Sources/FMServerBar/
    ├── main.swift                   # @main App, MenuBarExtra scene + view
    ├── ServerController.swift       # Process lifecycle: start/stop `fm serve`
    ├── HealthPoller.swift           # async GET /health → parsed status
    └── AppState.swift               # @MainActor ObservableObject binding UI ↔ controller/poller
```

### Responsibilities

- **`ServerController`** — owns a `Foundation.Process` running
  `/usr/bin/fm serve --port <port>`. `start(port:)`, `stop()`. Detects launch
  failure and premature exit via `terminationHandler`. The ONLY file that
  spawns a subprocess.
- **`HealthPoller`** — `func poll(port:) async -> Health?` doing a short-timeout
  `URLSession` GET to `http://127.0.0.1:<port>/health`, decoding the JSON into
  a `Health` struct (`status`, `[ModelHealth]` with `name`, `available`,
  `reason?`). Pure networking; no UI, no process handling.
- **`AppState`** — `@MainActor ObservableObject`: `port` (UserDefaults, default
  1976), `isProcessRunning`, `health: Health?`, `lastPoll`. Drives a repeating
  poll `Task`. Computes `statusColor`. Wires Start/Stop/Apply to
  `ServerController`.
- **`main.swift`** — `MenuBarExtra` UI; creates `AppState`; auto-starts on
  launch; terminates subprocess on quit.

## Menu-bar UI

Status-tinted SF Symbol (`brain` → `apple.intelligence` → `sparkles` fallback),
non-template `NSImage` colored via `SymbolConfiguration`:
- 🟢 green — process running AND `system` available
- 🟡 yellow — process running but a model unavailable (or health not yet read)
- 🔴 red — process stopped or failed to launch

Menu:
```
FM Server — ● Running on :1976    (or ○ Stopped / ⚠ Failed to launch)
system: ✓ available
pcc:    ✓ available            (or: ✗ <reason>)
─────────────────────────
Base URL:  http://127.0.0.1:1976/v1     [Copy]
Port:      [ 1976 ]  (Apply restarts server)
─────────────────────────
[ Stop Server ]  (toggles)
Last checked: 10:42:07
─────────────────────────
Launch at Login   ☐        (off by default; SMAppService)
Quit   (stops fm serve)
```

## Lifecycle & error handling

- **Auto-start:** on launch, `AppState.start()` → `ServerController.start(port:)`.
- **Poll loop:** a repeating `Task` calls `HealthPoller.poll` every ~3s while
  the app is alive; updates `health` + `lastPoll`. A failed poll (connection
  refused) while the process is supposed to be running → treat as not-ready
  (yellow), or red if the process also died.
- **Port change:** Apply → `stop()` then `start(port:)` on the new port; persist.
- **Subprocess dies unexpectedly:** `terminationHandler` sets
  `isProcessRunning = false`; icon → red; menu shows "Failed / exited".
- **Quit:** `NSApplication` termination → `ServerController.stop()`
  (`process.terminate()`), then exit. Guard against orphaned processes by also
  stopping any existing `fm serve` we spawned before starting a new one.

## Testing

- **Unit test** (`HealthPollerTests`): decode the known `/health` JSON into
  `Health`; assert `system.available == true`, `pcc` reason mapping when
  present. Pure decode, no network.
- **Manual/E2E:**
  1. `open FMServerBar.app` → green icon appears, no Dock icon.
  2. `curl http://127.0.0.1:1976/health` → matches menu display.
  3. In FluidVoice: Base URL `http://127.0.0.1:1976/v1`, Refresh models →
     `system` + `pcc`; run a `pcc` completion → confirms PCC works from the
     app's Aqua-session subprocess (the key open question).
  4. Quit app → `pgrep -f "fm serve"` returns nothing (no orphan).
- `ServerController` not unit-tested (spawns a real process); covered by E2E.

## Out of scope (YAGNI)

- Reimplementing the HTTP server (fm serve does it).
- Multiple simultaneous servers / socket mode.
- Editing model set (fixed by fm: system + pcc).
