# FMServerBar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu-bar app that launches/stops Apple's `fm serve` subprocess and shows its `/health` status, so Foundation Models is available as a local OpenAI-compatible endpoint with one click.

**Architecture:** SwiftPM executable (`FMServerBar`), `LSUIElement` agent app. `ServerController` runs `/usr/bin/fm serve --port <port>` via `Foundation.Process`; `HealthPoller` polls `GET /health`; `AppState` (`@MainActor ObservableObject`) binds them to a `MenuBarExtra` UI. No HTTP server is reimplemented.

**Tech Stack:** Swift 6.3, SwiftUI `MenuBarExtra`, `Foundation.Process`, `URLSession`, swift-testing. Targets macOS 26.

**Confirmed facts (verified 2026-08-19):**
- `fm` binary: `/usr/bin/fm`; default port **1976**.
- `/health` → `{"status":"fm serve is running","models":[{"name":"system","available":true},{"name":"pcc","available":true}]}` (`reason: String?` when unavailable).

---

## File Structure

```
~/FMServerBar/
├── Package.swift                       # executable + test targets, macOS 26
├── Info.plist                          # LSUIElement=true
├── build-app.sh                        # bundle .app + ad-hoc codesign
├── Sources/FMServerBar/
│   ├── HealthPoller.swift              # Health types + GET /health (Task 2)
│   ├── ServerController.swift          # Process lifecycle (Task 3)
│   ├── AppState.swift                  # ObservableObject (Task 4)
│   └── main.swift                      # MenuBarExtra app (Task 5)
└── Tests/FMServerBarTests/
    └── HealthPollerTests.swift         # decode /health JSON (Task 2)
```

---

## Task 1: Scaffold SwiftPM package

**Files:**
- Create: `~/FMServerBar/Package.swift`
- Create: `~/FMServerBar/Sources/FMServerBar/main.swift` (temporary stub)

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FMServerBar",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "FMServerBar", path: "Sources/FMServerBar"),
        .testTarget(name: "FMServerBarTests", dependencies: ["FMServerBar"], path: "Tests/FMServerBarTests"),
    ]
)
```

- [ ] **Step 2: Write a temporary `main.swift` stub**

```swift
print("FMServerBar placeholder")
```

- [ ] **Step 3: Build to verify the package is valid**

Run: `cd ~/FMServerBar && swift build`
Expected: `Build complete!`.

- [ ] **Step 4: Commit**

```bash
cd ~/FMServerBar && git add -A && git commit -m "chore: scaffold FMServerBar SwiftPM package"
```

---

## Task 2: HealthPoller — types + JSON decode (TDD)

**Files:**
- Create: `~/FMServerBar/Sources/FMServerBar/HealthPoller.swift`
- Test: `~/FMServerBar/Tests/FMServerBarTests/HealthPollerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import FMServerBar

@Test func decodesHealthJSON() throws {
    let json = """
    {"status":"fm serve is running","models":[
      {"name":"system","available":true},
      {"name":"pcc","available":false,"reason":"Private Cloud Compute is not available in this context."}]}
    """.data(using: .utf8)!
    let health = try JSONDecoder().decode(Health.self, from: json)
    #expect(health.status == "fm serve is running")
    #expect(health.models.count == 2)
    #expect(health.model(named: "system")?.available == true)
    #expect(health.model(named: "pcc")?.available == false)
    #expect(health.model(named: "pcc")?.reason?.contains("not available") == true)
    #expect(health.systemAvailable == true)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/FMServerBar && swift test --filter decodesHealthJSON`
Expected: FAIL — `Health` undefined.

- [ ] **Step 3: Implement `HealthPoller.swift`**

```swift
import Foundation

struct ModelHealth: Codable, Equatable {
    let name: String
    let available: Bool
    let reason: String?
}

struct Health: Codable, Equatable {
    let status: String
    let models: [ModelHealth]

    func model(named name: String) -> ModelHealth? { models.first { $0.name == name } }
    var systemAvailable: Bool { model(named: "system")?.available ?? false }
}

enum HealthPoller {
    /// GET http://127.0.0.1:<port>/health with a short timeout. Returns nil on any failure.
    static func poll(port: Int) async -> Health? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(Health.self, from: data)
        } catch {
            return nil
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/FMServerBar && swift test --filter decodesHealthJSON`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd ~/FMServerBar && git add -A && git commit -m "feat: HealthPoller with Health types and /health decode"
```

---

## Task 3: ServerController — Process lifecycle

**Files:**
- Create: `~/FMServerBar/Sources/FMServerBar/ServerController.swift`

Not unit-tested (spawns a real process); covered by E2E in Task 6.

- [ ] **Step 1: Implement `ServerController.swift`**

```swift
import Foundation

/// Owns a `fm serve` subprocess. The only file that spawns a process.
final class ServerController {
    private var process: Process?
    private let fmPath = "/usr/bin/fm"

    /// Called on the main thread when the process exits (expected or not).
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

    func start(port: Int) {
        stop()  // guard against orphaning a previous instance
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: fmPath)
        proc.arguments = ["serve", "--port", String(port)]
        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            DispatchQueue.main.async { self?.process = nil; self?.onExit?(code) }
        }
        do {
            try proc.run()
            self.process = proc
        } catch {
            self.process = nil
            DispatchQueue.main.async { self.onExit?(-1) }
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else { process = nil; return }
        proc.terminationHandler = nil
        proc.terminate()
        process = nil
    }
}
```

- [ ] **Step 2: Build**

Run: `cd ~/FMServerBar && swift build`
Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
cd ~/FMServerBar && git add -A && git commit -m "feat: ServerController managing fm serve subprocess"
```

---

## Task 4: AppState — binding controller + poller to UI

**Files:**
- Create: `~/FMServerBar/Sources/FMServerBar/AppState.swift`

- [ ] **Step 1: Implement `AppState.swift`**

```swift
import Foundation
import SwiftUI
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    @Published var port: Int { didSet { UserDefaults.standard.set(port, forKey: "port") } }
    @Published var isProcessRunning = false
    @Published var health: Health?
    @Published var lastPoll: String?
    @Published var launchFailed = false
    @Published var launchAtLogin = false

    private let controller = ServerController()
    private var pollTask: Task<Void, Never>?

    init() {
        let saved = UserDefaults.standard.integer(forKey: "port")
        self.port = saved == 0 ? 1976 : saved
        controller.onExit = { [weak self] code in
            guard let self else { return }
            self.isProcessRunning = false
            self.launchFailed = (code != 0)
            self.health = nil
        }
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    func start() {
        launchFailed = false
        controller.start(port: port)
        isProcessRunning = controller.isRunning
        startPolling()
    }

    func stop() {
        controller.stop()
        isProcessRunning = false
        health = nil
        pollTask?.cancel(); pollTask = nil
    }

    func applyPort() { stop(); start() }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let h = await HealthPoller.poll(port: self.port)
                await MainActor.run {
                    self.health = h
                    self.isProcessRunning = self.controller.isRunning
                    self.lastPoll = Self.clock()
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// HH:mm:ss without Date APIs disallowed in some contexts — use a formatter on a fresh Date is fine in an app.
    private static func clock() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    func copyBaseURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(baseURL, forType: .string)
    }

    /// Register/unregister the .app as a login item. Only effective from the
    /// packaged, signed .app — not `swift run`. Reflects real state back to UI.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // Registration can fail (e.g. run from swift run, or Gatekeeper).
            // Surface as launchFailed-style feedback via lastPoll text.
            lastPoll = "Login item error: \(error.localizedDescription)"
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    /// green = running + system available; yellow = running but not (yet) available; red = stopped/failed.
    var statusColor: Color {
        if launchFailed { return .red }
        if !isProcessRunning { return .red }
        return (health?.systemAvailable ?? false) ? .green : .yellow
    }

    func shutdown() { stop() }
}
```

- [ ] **Step 2: Build**

Run: `cd ~/FMServerBar && swift build`
Expected: `Build complete!`.

- [ ] **Step 3: Commit**

```bash
cd ~/FMServerBar && git add -A && git commit -m "feat: AppState wiring controller, poller, and status"
```

---

## Task 5: MenuBarExtra UI + app entry

**Files:**
- Modify: `~/FMServerBar/Sources/FMServerBar/main.swift` (replace stub)

- [ ] **Step 1: Replace `main.swift`**

```swift
import SwiftUI
import AppKit

@main
struct FMServerBarApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(nsImage: Self.statusIcon(color: state.statusColor))
        }
        .menuBarExtraStyle(.window)
    }

    static func statusIcon(color: Color) -> NSImage {
        let names = ["brain", "apple.intelligence", "sparkles"]
        let symbol = names.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: "FM Server")
        }.first ?? NSImage()
        let config = NSImage.SymbolConfiguration(paletteColors: [NSColor(color)])
        let img = symbol.withSymbolConfiguration(config) ?? symbol
        img.isTemplate = false
        return img
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline).font(.headline)
            if let models = state.health?.models {
                ForEach(models, id: \.name) { m in
                    Text("\(m.name): \(m.available ? "✓ available" : "✗ \(m.reason ?? "unavailable")")")
                        .font(.caption).foregroundStyle(m.available ? .primary : .secondary)
                }
            } else if state.isProcessRunning {
                Text("Starting…").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text(state.baseURL).font(.system(.caption, design: .monospaced))
                Button("Copy") { state.copyBaseURL() }
            }
            HStack {
                Text("Port:")
                TextField("Port", value: $state.port, format: .number.grouping(.never)).frame(width: 70)
                Button("Apply") { state.applyPort() }
            }
            Divider()
            Button(state.isProcessRunning ? "Stop Server" : "Start Server") {
                state.isProcessRunning ? state.stop() : state.start()
            }
            if let last = state.lastPoll {
                Text("Last checked: \(last)").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Launch at Login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            .font(.caption)
            Button("Quit") { state.shutdown(); NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { if !state.isProcessRunning { state.start() } }
    }

    private var headline: String {
        if state.launchFailed { return "⚠ Failed to launch fm serve" }
        return state.isProcessRunning ? "● Running on :\(state.port)" : "○ Stopped"
    }
}
```

- [ ] **Step 2: Build**

Run: `cd ~/FMServerBar && swift build`
Expected: `Build complete!`. If `NSColor(Color)` bridging errors, add a `statusNSColor` on `AppState` mapping to `.systemGreen/.systemYellow/.systemRed` and use it here.

- [ ] **Step 3: Commit**

```bash
cd ~/FMServerBar && git add -A && git commit -m "feat: MenuBarExtra UI with per-model status and controls"
```

---

## Task 6: Bundle app + end-to-end verification

**Files:**
- Create: `~/FMServerBar/Info.plist`
- Create: `~/FMServerBar/build-app.sh`

- [ ] **Step 1: Write `Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>FMServerBar</string>
    <key>CFBundleIdentifier</key><string>local.fmserverbar</string>
    <key>CFBundleName</key><string>FM Server</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
```

- [ ] **Step 2: Write `build-app.sh`**

```bash
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
```

- [ ] **Step 3: Build the app**

Run: `cd ~/FMServerBar && chmod +x build-app.sh && ./build-app.sh`
Expected: `Built FMServerBar.app` with no codesign errors.

- [ ] **Step 4: Stop any manually-running fm serve, then launch the app**

Run:
```bash
pkill -f "fm serve" 2>/dev/null; sleep 1
open ~/FMServerBar/FMServerBar.app
sleep 4
```
Expected: menu-bar icon appears (green), no Dock icon.

- [ ] **Step 5: Verify the app started fm serve and health matches**

Run: `curl -s http://127.0.0.1:1976/health`
Expected: JSON with `system available:true` (and `pcc` availability), matching the menu display.

- [ ] **Step 6: Verify PCC works from the app's subprocess (the key check)**

Run:
```bash
curl -s http://127.0.0.1:1976/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"pcc","messages":[{"role":"user","content":"say hi in 3 words"}]}' | head -c 400
```
Expected: a completion (not a `model_unavailable` error). If PCC is unavailable from the app context, the menu will honestly show `pcc: ✗ <reason>` and `system` still works — record the outcome either way.

- [ ] **Step 7: Verify no orphan on quit**

Manually quit via the menu's Quit, then run: `pgrep -f "fm serve" || echo "no orphan"`
Expected: `no orphan`.

- [ ] **Step 8: Verify Launch at Login toggle**

Relaunch `open ~/FMServerBar/FMServerBar.app`, click the menu's **Launch at Login** checkbox on, then run:
```bash
sfltool dumpbtm 2>/dev/null | grep -i fmserverbar || echo "check System Settings > General > Login Items for 'FM Server'"
```
Expected: the app appears as a registered login item (checkbox stays checked; no "Login item error" in the menu). Toggle it back off to confirm unregister works.
Note: this only works from the packaged `.app`; `swift run` will show a registration error, which is expected.

- [ ] **Step 9: Verify FluidVoice**

FluidVoice Custom Provider: Base URL `http://127.0.0.1:1976/v1`, any API key, Refresh models → `system` + `pcc` selectable; run a completion.
Expected: works; "Connection not tested" clears.

- [ ] **Step 10: Commit**

```bash
cd ~/FMServerBar && git add -A && git commit -m "build: app bundle + verified end-to-end with FluidVoice"
```

---

## Notes for the implementer

- **Aqua context is the whole point:** the app is launched by the user (GUI/Aqua session), so its `fm serve` subprocess should inherit the context PCC needs — unlike a sandboxed shell or possibly a headless daemon. Step 6 verifies this empirically.
- **No orphans:** `ServerController.start` calls `stop()` first, and Quit calls `shutdown()`. If a crash ever leaves one, `pkill -f "fm serve"` clears it.
- **Polling cadence:** 3s is responsive without being chatty. A failed poll while the process is alive shows yellow (starting/unavailable), not red.
- **Date usage:** unlike workflow scripts, a normal app may use `Date()`/`DateFormatter` freely — used only for the "Last checked" label.
- **Launch at Login:** `SMAppService.mainApp` registers the `.app` bundle itself. It only works from the packaged, signed `.app` (Task 6), not `swift run` — a registration error there is expected. Off by default; state is read back from `SMAppService.mainApp.status` so the checkbox reflects reality. Because login-launch keeps the Aqua GUI session, PCC continues to work.
- **If `.macOS("26.0")` errors:** match the exact platform string SwordSlice's `Package.swift` uses.
