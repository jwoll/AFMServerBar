# FMServerBar PCC-Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add a "Model context" toggle to FMServerBar so the user can switch between On-device (background, direct subprocess) and PCC (launched via Terminal.app so Private Cloud Compute works), minimizing just the fm serve Terminal window.

**Architecture:** Extend `ServerController` with a `LaunchMode { .direct, .terminal }` passed to `start(port:mode:)`. `.direct` keeps the existing `Process` path. `.terminal` uses `osascript` to run `fm serve` inside Terminal.app, minimizes that window, then discovers the child PID via `pgrep` and stores it in the same `lastChildPID` slot so stop/reap are uniform. `AppState` gains a persisted `useTerminalForPCC` bool; toggling stops the old server then starts in the new mode. The menu adds the toggle + a caption.

**Tech Stack:** Swift 6.3, existing FMServerBar package. Uses `osascript`, `pgrep`.

**Verified mechanism (2026-08-19):** PCC is gated on responsible-process attribution. `fm serve` run via `osascript ... tell application "Terminal" to do script "fm serve --port N"` → `pcc: available` + real completions. Minimizing just that window (`set miniaturized of <window> to true`) preserves PCC and leaves other Terminal windows alone. The Terminal-launched child is findable/killable by PID (`pgrep -f "fm serve --port N"`, then SIGTERM).

---

## File Structure (changes only)

```
Sources/FMServerBar/
├── ServerController.swift   # + LaunchMode enum, start(port:mode:), terminal launch + window mgmt (Task 1)
├── AppState.swift           # + useTerminalForPCC persisted bool, mode plumbing (Task 2)
└── FMServerBarApp.swift     # + Model context toggle + caption (Task 3)
```

---

## Task 1: ServerController — LaunchMode + Terminal launch

**Files:**
- Modify: `~/FMServerBar/Sources/FMServerBar/ServerController.swift`

Current `ServerController` has: `process: Process?`, `fmPath`, `onExit`, `isRunning`, `reapOwnOrphan()`, `start(port:)`, `stop()`, all using `lastChildPID` in UserDefaults. You are EXTENDING it, preserving all existing behavior for the direct path.

- [ ] **Step 1: Add the LaunchMode enum and a stored current port/mode**

At the top of the class (after `private let fmPath`), add:

```swift
enum LaunchMode: String { case direct, terminal }

/// The port the currently-running server was started on (for terminal-mode PID
/// discovery and window cleanup). 0 when nothing is running.
private var currentPort: Int = 0
private var currentMode: LaunchMode = .direct
```

- [ ] **Step 2: Rename `start(port:)` to `start(port:mode:)` and branch**

Replace the existing `func start(port: Int)` with:

```swift
func start(port: Int, mode: LaunchMode = .direct) {
    reapOwnOrphan()   // kill only our own orphan from a prior app lifetime
    stop()            // guard against orphaning a previous instance
    currentPort = port
    currentMode = mode
    switch mode {
    case .direct:   startDirect(port: port)
    case .terminal: startTerminal(port: port)
    }
}

private func startDirect(port: Int) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: fmPath)
    proc.arguments = ["serve", "--port", String(port)]
    proc.terminationHandler = { [weak self] p in
        let code = p.terminationStatus
        DispatchQueue.main.async { self?.process = nil; self?.onExit?(code) }
    }
    do {
        try proc.run()
        UserDefaults.standard.set(Int(proc.processIdentifier), forKey: "lastChildPID")
        self.process = proc
    } catch {
        self.process = nil
        DispatchQueue.main.async { self.onExit?(-1) }
    }
}
```

Note: `startDirect` is exactly the OLD body of `start(port:)` — unchanged behavior.

- [ ] **Step 3: Implement `startTerminal(port:)`**

Add:

```swift
/// Launches `fm serve` INSIDE Terminal.app so Terminal is the responsible
/// process (required for Private Cloud Compute). Minimizes just that window,
/// then discovers the child PID and stores it in `lastChildPID` so stop()/
/// reapOwnOrphan() work identically to the direct path.
private func startTerminal(port: Int) {
    // AppleScript: run fm serve in a new Terminal window, then minimize that window.
    let script = """
    tell application "Terminal"
        set w to do script "exec fm serve --port \(port)"
        delay 1
        try
            set miniaturized of (first window whose tabs contains w) to true
        end try
    end tell
    """
    let osa = Process()
    osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    osa.arguments = ["-e", script]
    osa.standardError = FileHandle.nullDevice
    osa.standardOutput = FileHandle.nullDevice
    do {
        try osa.run()
        osa.waitUntilExit()
    } catch {
        DispatchQueue.main.async { self.onExit?(-1) }
        return
    }
    // The server runs inside Terminal, not as our direct child, so we have no
    // Process handle. Discover its PID by port and store it for stop()/reap.
    // Retry briefly since Terminal + fm take a moment to spawn.
    var found: Int32 = 0
    for _ in 0..<20 {   // up to ~4s
        if let pid = Self.pidOfServer(port: port) { found = pid; break }
        usleep(200_000)
    }
    if found > 0 {
        UserDefaults.standard.set(Int(found), forKey: "lastChildPID")
        // No Process handle in terminal mode; `process` stays nil. isRunning
        // will report false, so AppState relies on /health polling for status
        // in terminal mode (see Task 2).
    } else {
        DispatchQueue.main.async { self.onExit?(-1) }
    }
}

/// Finds the PID of an `fm serve --port <port>` process via pgrep. Returns the
/// first match, or nil if none.
private static func pidOfServer(port: Int) -> Int32? {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", "fm serve --port \(port)"]
    let pipe = Pipe()
    pgrep.standardOutput = pipe
    pgrep.standardError = FileHandle.nullDevice
    do { try pgrep.run(); pgrep.waitUntilExit() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let out = String(data: data, encoding: .utf8) ?? ""
    // pgrep may return multiple PIDs (one per line); take the first numeric.
    for line in out.split(separator: "\n") {
        if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) { return pid }
    }
    return nil
}
```

- [ ] **Step 4: Update `stop()` to handle terminal mode (kill by PID + close window)**

Replace the existing `stop()` with:

```swift
func stop() {
    // Direct mode: we hold a Process handle.
    if let proc = process, proc.isRunning {
        proc.terminationHandler = nil
        proc.terminate()
        process = nil
    } else if currentMode == .terminal {
        // Terminal mode: kill the tracked PID and close its Terminal window.
        let pid = UserDefaults.standard.integer(forKey: "lastChildPID")
        if pid > 0 { kill(pid_t(pid), SIGTERM) }
        closeTerminalWindow(port: currentPort)
    }
    process = nil
    UserDefaults.standard.removeObject(forKey: "lastChildPID")
    currentPort = 0
}

/// Closes the Terminal window running `fm serve --port <port>`, if any.
private func closeTerminalWindow(port: Int) {
    let script = """
    tell application "Terminal"
        try
            close (every window whose name contains "fm serve --port \(port)")
        end try
    end tell
    """
    let osa = Process()
    osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    osa.arguments = ["-e", script]
    osa.standardError = FileHandle.nullDevice
    osa.standardOutput = FileHandle.nullDevice
    try? osa.run()
    osa.waitUntilExit()
}
```

- [ ] **Step 5: Build**

Run: `cd ~/FMServerBar && swift build`
Expected: `Build complete!`. Report warnings. (Watch: Swift 6 concurrency on the new Process uses — they're local and synchronous, same pattern as reapOwnOrphan, so should be fine.)

- [ ] **Step 6: Commit**

```bash
cd ~/FMServerBar && git add -A && git -c user.name='Claude' -c user.email='claude@local' commit -m "feat: ServerController launch modes (direct + Terminal-for-PCC)"
```

---

## Task 2: AppState — mode plumbing

**Files:**
- Modify: `~/FMServerBar/Sources/FMServerBar/AppState.swift`

Current AppState has `@Published port`, `isProcessRunning`, `health`, `lastPoll`, `launchFailed`, `launchAtLogin`; a `controller`; `start()/stop()/applyPort()/...`; and calls `controller.start(port: port)`.

- [ ] **Step 1: Add the persisted mode property**

After the existing `@Published var launchAtLogin = false` line, add:

```swift
@Published var useTerminalForPCC: Bool {
    didSet { UserDefaults.standard.set(useTerminalForPCC, forKey: "useTerminalForPCC") }
}
```

In `init()`, before `start()`, initialize it (default false):

```swift
self.useTerminalForPCC = UserDefaults.standard.bool(forKey: "useTerminalForPCC")
```

(`UserDefaults.bool` returns false when unset — correct default.)

- [ ] **Step 2: Pass the mode into `controller.start`**

In `func start()`, change:

```swift
controller.start(port: port)
```
to:

```swift
controller.start(port: port, mode: useTerminalForPCC ? .terminal : .direct)
```

Also, because terminal-mode has no Process handle (`controller.isRunning` is false there), update the line after it so the UI still shows "running" in terminal mode. Change:

```swift
isProcessRunning = controller.isRunning
```
to:

```swift
// In terminal mode there's no Process handle; treat a successful start as
// running and let /health polling confirm. In direct mode use the handle.
isProcessRunning = useTerminalForPCC ? true : controller.isRunning
```

- [ ] **Step 3: Add a toggle handler that restarts in the new mode**

Add this method (near `applyPort`):

```swift
/// Switch between direct (on-device background) and Terminal-launched (PCC) mode.
/// Stops the current server first, then starts in the new mode.
func setUseTerminalForPCC(_ enabled: Bool) {
    useTerminalForPCC = enabled
    stop()
    start()
}
```

- [ ] **Step 4: Build**

Run: `cd ~/FMServerBar && swift build`
Expected: `Build complete!`. Report warnings.

- [ ] **Step 5: Commit**

```bash
cd ~/FMServerBar && git add -A && git -c user.name='Claude' -c user.email='claude@local' commit -m "feat: AppState PCC/Terminal launch mode toggle"
```

---

## Task 3: Menu UI — Model context toggle

**Files:**
- Modify: `~/FMServerBar/Sources/FMServerBar/FMServerBarApp.swift`

- [ ] **Step 1: Add the toggle + caption to MenuContent**

In `MenuContent.body`, immediately BEFORE the existing `Toggle("Launch at Login", ...)` block, insert:

```swift
Toggle("Enable PCC (via Terminal)", isOn: Binding(
    get: { state.useTerminalForPCC },
    set: { state.setUseTerminalForPCC($0) }
))
.font(.caption)
if state.useTerminalForPCC {
    Text("Runs fm serve in a minimized Terminal window — keep it open for PCC.")
        .font(.caption2).foregroundStyle(.secondary)
}
Divider()
```

Leave everything else in the view unchanged.

- [ ] **Step 2: Build**

Run: `cd ~/FMServerBar && swift build`
Expected: `Build complete!`. Report warnings.

- [ ] **Step 3: Commit**

```bash
cd ~/FMServerBar && git add -A && git -c user.name='Claude' -c user.email='claude@local' commit -m "feat: Model context (PCC) toggle in menu"
```

---

## Task 4: Rebuild bundle + end-to-end verification

**Files:** none (verification only).

- [ ] **Step 1: Rebuild the app bundle**

Run: `cd ~/FMServerBar && ./build-app.sh 2>&1 | tail -2`
Expected: `Built FMServerBar.app`.

- [ ] **Step 2: Launch and verify default (on-device) mode**

Run:
```bash
pkill -f "fm serve" 2>/dev/null; pkill -9 -f "FMServerBar.app" 2>/dev/null; sleep 2
open ~/FMServerBar/FMServerBar.app; sleep 5
curl -s http://127.0.0.1:1976/health
```
Expected: `system available:true`, `pcc available:false` (direct mode). No Terminal window opened.

- [ ] **Step 3: Simulate enabling PCC via defaults + relaunch (proxy for the toggle)**

Since the toggle calls `setUseTerminalForPCC(true)` → stop()+start(.terminal), verify the terminal path works by setting the persisted flag and relaunching:
```bash
pkill -9 -f "FMServerBar.app" 2>/dev/null; sleep 2
defaults write local.fmserverbar useTerminalForPCC -bool true
open ~/FMServerBar/FMServerBar.app; sleep 7
echo "=== health (should now show pcc available) ==="
curl -s http://127.0.0.1:1976/health
echo "=== a real pcc completion ==="
curl -s http://127.0.0.1:1976/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"pcc","messages":[{"role":"user","content":"say hi in 3 words"}]}' | head -c 300
```
Expected: `pcc available:true`; the completion returns content (not a 503). A minimized Terminal window exists.
NOTE: `defaults write` uses the bundle id `local.fmserverbar`. If the app reads/writes a suite, confirm the domain; adjust if needed. This step is a proxy — the real toggle is exercised manually in Step 5.

- [ ] **Step 4: Verify a user's own fm serve is NOT killed**

Run (on a free port, while app is running):
```bash
/usr/bin/fm serve --port 45678 >/tmp/user_fm.log 2>&1 &
sleep 4
USER=$(pgrep -f "fm serve --port 45678")
# trigger an app restart of ITS server by toggling defaults + relaunch
pkill -9 -f "FMServerBar.app" 2>/dev/null; sleep 2
open ~/FMServerBar/FMServerBar.app; sleep 6
ps -p $USER -o pid= >/dev/null 2>&1 && echo "user server SURVIVED (correct)" || echo "user server KILLED (bug)"
pkill -f "fm serve --port 45678" 2>/dev/null
```
Expected: `user server SURVIVED`.

- [ ] **Step 5: Manual toggle check + cleanup**

Manually: open the menu, toggle "Enable PCC (via Terminal)" off and on, confirm the menu shows `pcc: ✓ available` when on and the caption appears; confirm a minimized Terminal window appears when on and closes when off/quit. Then reset:
```bash
defaults write local.fmserverbar useTerminalForPCC -bool false
pkill -9 -f "FMServerBar.app" 2>/dev/null; pkill -f "fm serve" 2>/dev/null
osascript -e 'tell application "Terminal" to close (every window whose name contains "fm serve")' 2>/dev/null
```

- [ ] **Step 6: Commit verification note**

```bash
cd ~/FMServerBar && git commit --allow-empty -m "test: verified PCC-via-Terminal toggle end-to-end" && git -c user.name='Claude' -c user.email='claude@local' commit --amend --no-edit 2>/dev/null; true
```

---

## Notes for the implementer

- **Do not break the direct path.** `startDirect` must be byte-for-byte the old `start(port:)` body. All existing tests/behavior for on-device mode must still hold.
- **Terminal mode has no Process handle.** `isRunning` (handle-based) is false in terminal mode by design; AppState compensates (Task 2 Step 2) and status comes from `/health` polling. Do not try to fake a Process handle.
- **PID tracking is uniform:** both modes store the server PID in `lastChildPID`, so `reapOwnOrphan()` and `stop()` work for both. The Terminal-launched PID is the `fm` process (child of Terminal), which SIGTERM stops cleanly (verified).
- **The `exec` in the AppleScript** (`do script "exec fm serve..."`) makes `fm` replace the shell so the window's process IS fm serve — makes the window name contain the command and the PID discoverable. Keep it.
- **Responsible-process constraint:** never try to detach fm from Terminal or close the window while running in PCC mode — that breaks PCC. Minimize only.
