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
    @Published var useTerminalForPCC: Bool {
        didSet { UserDefaults.standard.set(useTerminalForPCC, forKey: "useTerminalForPCC") }
    }

    private let controller = ServerController()
    private var pollTask: Task<Void, Never>?

    init() {
        let saved = UserDefaults.standard.integer(forKey: "port")
        self.port = saved == 0 ? 1976 : saved
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        self.useTerminalForPCC = UserDefaults.standard.bool(forKey: "useTerminalForPCC")
        controller.onExit = { [weak self] code in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.isProcessRunning = false
                self.launchFailed = (code != 0)
                self.health = nil
            }
        }
        // Stop the server on EVERY termination path (menu Quit, ⌘Q, osascript
        // quit, logout) — self-contained, doesn't depend on the Quit button's
        // closure (which AppKit bypasses) or delegate-wiring timing.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
        start()
    }

    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    func start() {
        launchFailed = false
        let port = self.port
        let mode: ServerController.LaunchMode = useTerminalForPCC ? .terminal : .direct
        // Terminal-mode launch blocks for several seconds (osascript + pgrep poll),
        // so run the controller start off the main actor to avoid beachballing.
        // In terminal mode there's no Process handle, so optimistically mark running
        // and let /health polling confirm; direct mode confirms via controller.isRunning.
        isProcessRunning = (mode == .terminal)
        Task.detached { [controller] in
            controller.start(port: port, mode: mode)
        }
        if mode == .direct {
            controller.isRunningAsync { [weak self] running in
                MainActor.assumeIsolated { self?.isProcessRunning = running }
            }
        }
        startPolling()
    }

    func stop() {
        controller.stop()
        isProcessRunning = false
        health = nil
        pollTask?.cancel(); pollTask = nil
    }

    func applyPort() { stop(); start() }

    /// Switch between direct (on-device background) and Terminal-launched (PCC) mode.
    /// Stops the current server first, then starts in the new mode.
    func setUseTerminalForPCC(_ enabled: Bool) {
        useTerminalForPCC = enabled
        stop()
        start()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let h = await HealthPoller.poll(port: self.port)
                await MainActor.run {
                    self.health = h
                    self.isProcessRunning = self.useTerminalForPCC ? (self.health != nil) : self.controller.isRunning
                    self.lastPoll = Self.clock()
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// HH:mm:ss label for "last checked".
    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private static func clock() -> String { clockFormatter.string(from: Date()) }

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

    /// Called on app quit: stop the server SYNCHRONOUSLY so the terminal-mode
    /// child and its window are cleaned up before NSApplication terminates.
    func shutdown() {
        pollTask?.cancel(); pollTask = nil
        controller.stopBlocking()
    }
}
