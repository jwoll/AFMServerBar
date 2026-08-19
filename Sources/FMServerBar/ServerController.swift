import Foundation
import Darwin

/// Owns a `fm serve` subprocess. The only file that spawns a process.
final class ServerController: @unchecked Sendable {
    private var process: Process?
    private let fmPath = "/usr/bin/fm"

    /// Called on the main thread when the process exits (expected or not).
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

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

    func start(port: Int) {
        reapOwnOrphan()  // kill only our own orphan from a prior app lifetime
        stop()           // guard against orphaning a previous instance
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

    func stop() {
        guard let proc = process, proc.isRunning else { process = nil; return }
        proc.terminationHandler = nil
        proc.terminate()
        process = nil
        // A cleanly stopped child is not an orphan — clear the stored PID so
        // reapOwnOrphan() on the next start() has nothing to act on.
        UserDefaults.standard.removeObject(forKey: "lastChildPID")
    }
}
