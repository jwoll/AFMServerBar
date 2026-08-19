import SwiftUI
import AppKit

/// Owns the shared AppState and guarantees the server is stopped on EVERY
/// termination path (menu Quit, ⌘Q, `osascript quit`, logout) — not just the
/// in-menu Quit button, whose closure AppKit bypasses on most quit routes.
/// Owning AppState here (rather than as a scene @StateObject) means cleanup does
/// not depend on the menu ever having been opened.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    func applicationWillTerminate(_ notification: Notification) {
        state.shutdown()   // synchronous: stops server + closes Terminal window
    }
}

@main
struct FMServerBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: delegate.state)
        } label: {
            Image(nsImage: Self.statusIcon(color: delegate.state.statusColor))
        }
        .menuBarExtraStyle(.window)
    }

    static func statusIcon(color: Color) -> NSImage {
        let names = ["brain", "apple.intelligence", "sparkles"]
        let symbol = names.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: "FM Server")
        }.first ?? NSImage()
        let sizeConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let colorConfig = NSImage.SymbolConfiguration(paletteColors: [NSColor(color)])
        let config = sizeConfig.applying(colorConfig)
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
            Toggle("Launch at Login", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            .font(.caption)
            Button("Quit") { state.shutdown(); NSApplication.shared.terminate(nil) }
        }
        .padding(12)
        .frame(width: 320)
    }

    private var headline: String {
        if state.launchFailed { return "⚠ Failed to launch fm serve" }
        return state.isProcessRunning ? "● Running on :\(state.port)" : "○ Stopped"
    }
}
