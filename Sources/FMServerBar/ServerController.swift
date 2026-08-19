import Foundation

/// Owns a `fm serve` subprocess. The only file that spawns a process.
final class ServerController: @unchecked Sendable {
    private var process: Process?
    private let fmPath = "/usr/bin/fm"

    /// Called on the main thread when the process exits (expected or not).
    var onExit: ((Int32) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

    /// Kills any stray `fm serve --port <port>` processes left over from a
    /// previous app lifetime (e.g. force-kill or crash). Uses `pkill -f` so
    /// the match is against the full argument list including the exact port
    /// number — processes on other ports are never touched.
    private func reapStrayServers(port: Int) {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        // -f matches against the full command line; the port string makes the
        // pattern specific enough to avoid hitting unrelated fm invocations.
        pkill.arguments = ["-f", "fm serve --port \(port)"]
        // Suppress stdout/stderr — we don't care about pkill's output.
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        do {
            try pkill.run()
            pkill.waitUntilExit()
            // pkill exits 1 when nothing was matched — that is normal and
            // expected on a clean launch; ignore the status either way.
        } catch {
            // If pkill itself can't launch (e.g. path wrong), just continue.
        }
        // Give the kernel a moment to release the port after the signal lands.
        usleep(200_000)
    }

    func start(port: Int) {
        reapStrayServers(port: port)  // kill orphans from prior app lifetimes
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
