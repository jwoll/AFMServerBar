import Foundation

/// Owns a `fm serve` subprocess. The only file that spawns a process.
final class ServerController: @unchecked Sendable {
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
