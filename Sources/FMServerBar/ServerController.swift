import Foundation
import Darwin

/// Owns a `fm serve` subprocess. The only file that spawns a process.
final class ServerController: @unchecked Sendable {
    private var process: Process?
    private let fmPath = "/usr/bin/fm"

    enum LaunchMode: String { case direct, terminal }

    /// The port the currently-running server was started on (for terminal-mode PID
    /// discovery and window cleanup). 0 when nothing is running.
    private var currentPort: Int = 0
    private var currentMode: LaunchMode = .direct

    /// Serializes all start/stop/reap operations so a background (terminal-mode)
    /// launch can never race a main-thread stop() on the shared mutable state
    /// (process, currentPort, currentMode, lastChildPID).
    private let queue = DispatchQueue(label: "FMServerBar.ServerController")

    /// Called on the main thread when the process exits (expected or not).
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool {
        queue.sync { process?.isRunning ?? false }
    }

    /// Reaps only a child process THIS app previously spawned and left orphaned
    /// (e.g. due to a crash or force-quit). The candidate PID is read from
    /// UserDefaults ("lastChildPID") and is verified to still be running an
    /// `fm serve` command before any signal is sent — so a user's intentionally
    /// started `fm serve` (e.g. in Terminal.app for the PCC workaround on the
    /// same port) is never touched, because it will not match our stored PID.
    private func reapOwnOrphan() {
        let pid = UserDefaults.standard.integer(forKey: "lastChildPID")
        guard pid > 0 else { return }

        // Verify the PID still belongs to an fm serve process before killing it.
        // This guards against PID reuse: if the kernel handed the same PID to
        // an unrelated process we must not kill it.
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(pid), "-o", "command="]
        ps.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        ps.standardOutput = pipe
        do {
            try ps.run()
            ps.waitUntilExit()
        } catch {
            // ps failed to launch — play it safe and do nothing.
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        guard output.contains("fm") && output.contains("serve") else {
            // PID no longer points to our fm serve — clear the stale record.
            UserDefaults.standard.removeObject(forKey: "lastChildPID")
            return
        }

        // Confirmed: this is our orphaned fm serve. Terminate it gracefully.
        kill(pid_t(pid), SIGTERM)
        // Give the kernel a moment to release the port after the signal lands.
        usleep(200_000)
        // Clear the stored PID now that we've handled it.
        UserDefaults.standard.removeObject(forKey: "lastChildPID")
    }

    func start(port: Int, mode: LaunchMode = .direct) {
        queue.async { [weak self] in self?.performStart(port: port, mode: mode) }
    }

    private func performStart(port: Int, mode: LaunchMode = .direct) {
        reapOwnOrphan()   // kill only our own orphan from a prior app lifetime
        stopSync()        // guard against orphaning a previous instance
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
            // Persist this child's PID so a future app launch can reap it if
            // the app crashes or is force-quit before stop() is called.
            UserDefaults.standard.set(Int(proc.processIdentifier), forKey: "lastChildPID")
            self.process = proc
        } catch {
            self.process = nil
            DispatchQueue.main.async { self.onExit?(-1) }
        }
    }

    /// Launches `fm serve` INSIDE Terminal.app so Terminal is the responsible
    /// process (required for Private Cloud Compute). Minimizes just that window,
    /// then discovers the child PID and stores it in `lastChildPID` so stop()/
    /// reapOwnOrphan() work identically to the direct path.
    private func startTerminal(port: Int) {
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
            currentPort = 0
            currentMode = .direct
            DispatchQueue.main.async { self.onExit?(-1) }
            return
        }
        var found: Int32 = 0
        for _ in 0..<20 {   // up to ~4s
            if let pid = Self.pidOfServer(port: port) { found = pid; break }
            usleep(200_000)
        }
        if found > 0 {
            UserDefaults.standard.set(Int(found), forKey: "lastChildPID")
        } else {
            currentPort = 0
            currentMode = .direct
            DispatchQueue.main.async { self.onExit?(-1) }
        }
    }

    /// Finds the PID of an `fm serve --port <port>` process via pgrep. Returns the
    /// first match, or nil if none.
    private static func pidOfServer(port: Int) -> Int32? {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-fn", "fm serve --port \(port)"]   // -n = newest match (the one Terminal just launched)
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        do { try pgrep.run(); pgrep.waitUntilExit() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        for line in out.split(separator: "\n") {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) { return pid }
        }
        return nil
    }

    func stop() {
        queue.async { [weak self] in self?.stopSync() }
    }

    private func stopSync() {
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
}
