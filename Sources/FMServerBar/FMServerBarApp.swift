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
