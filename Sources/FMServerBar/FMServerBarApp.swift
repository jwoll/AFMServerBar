import SwiftUI
import AppKit

@main
struct FMServerBarApp: App {
    // AppState self-registers for NSApplication.willTerminateNotification, so
    // server cleanup runs on every quit path without an app delegate.
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(nsImage: Self.statusIcon(color: state.statusColor))
        }
        .menuBarExtraStyle(.window)
    }

    /// A solid status-colored disc with a white brain glyph inside it.
    /// Sized to the full menu-bar thickness so it's as large as possibly fits.
    static func statusIcon(color: Color) -> NSImage {
        let diameter: CGFloat = NSStatusBar.system.thickness   // full bar height (~22pt), edge-to-edge
        let img = NSImage(size: NSSize(width: diameter, height: diameter))
        img.lockFocus()
        // 1) filled status-colored circle
        NSColor(color).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
        // 2) white brain, ~72% of the diameter, centered
        let brainPt = diameter * 0.72
        let cfg = NSImage.SymbolConfiguration(pointSize: brainPt, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let base = NSImage(systemSymbolName: "brain.fill", accessibilityDescription: "FM Server"),
           let brain = base.withSymbolConfiguration(cfg) {
            brain.isTemplate = false
            let bs = brain.size
            let scale = min(brainPt / bs.width, brainPt / bs.height)
            let w = bs.width * scale, h = bs.height * scale
            brain.draw(in: NSRect(x: (diameter - w) / 2, y: (diameter - h) / 2, width: w, height: h))
        }
        img.unlockFocus()
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
