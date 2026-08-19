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
            MainActor.assumeIsolated {
                self.isProcessRunning = false
                self.launchFailed = (code != 0)
                self.health = nil
            }
        }
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        start()
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

    func shutdown() { stop() }
}
