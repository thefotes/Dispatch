import AppKit
import DispatchMacOS
import DispatchProviders
import SwiftUI

@main
struct DispatchMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            DispatchMenuView(model: appDelegate.model)
                .onAppear { Task { await appDelegate.model.refreshInputMonitoringPermission() } }
        } label: {
            DispatchStatusIcon(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Starts the runtime at launch. SwiftUI builds a menu bar extra's content
/// only when the menu first opens, so starting from the view would leave the
/// pad dead until the user clicked the icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await model.start() }
    }
}

private struct DispatchStatusIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(systemName: model.statusSymbol)
            .accessibilityLabel("Dispatch: \(model.statusTitle)")
    }
}

private struct DispatchMenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: model.statusSymbol)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Dispatch")
                            .font(.headline)
                        Text("v\(appVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(model.statusTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.isEnabled ? "Turn Off" : "Turn On") {
                    Task { await model.toggleEnabled() }
                }
            }

            if let issue = model.issueDescription {
                Label {
                    Text(issue)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
            }

            Divider()
            keymapSection
            Divider()
            providerSection
            Divider()
            configurationSection
            Divider()

            if model.inputMonitoringPermission == .denied {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Input Monitoring is needed to talk to the pad.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Grant Input Monitoring…") {
                            Task { await model.requestInputMonitoringPermission() }
                        }
                        Button("Open Settings") {
                            model.openInputMonitoringSettings()
                        }
                    }
                }
            }

            HStack {
                if model.accessibilityPermission == .denied {
                    Button("Grant Accessibility…") {
                        Task { await model.requestAccessibilityPermission() }
                    }
                }
                Spacer()
                Button("Quit") {
                    Task { await model.shutDownAndQuit() }
                }
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(PanelTopAnchorView())
    }

    private var keymapSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keymap").font(.subheadline.weight(.semibold))
            switch model.keymapStatus {
            case .consentNeeded:
                Text(
                    "The pad's keys need setup before Dispatch can use them. Setup replaces "
                        + "every key, dial direction, and joystick direction on the active "
                        + "profile's first layer. Your current layout is saved on the pad first, "
                        + "and you can restore it here or with dispatch-probe keymap-restore --write."
                )
                    .keymapNote()
                Button("Allow keymap setup") { Task { await model.allowKeymapSetup() } }
                    .disabled(model.snapshot.phase != .operational)
            case .waitingForPad:
                Text("The pad's keymap is checked once the pad is connected.").keymapNote()
            case .checking:
                Text("Checking the pad's keymap…").keymapNote()
            case .ready:
                Text("Dispatch input is ready.").keymapNote()
            case .changed:
                Text("Your pad's layout changed since Dispatch set it up.").keymapNote()
                VStack(alignment: .leading) {
                    Button("Apply Dispatch's layout again") { Task { await model.applyKeymap() } }
                    Button("Keep my layout (turn off keymap setup)") {
                        Task { await model.keepCurrentKeymap() }
                    }
                }
            case .disabled:
                Text("Keymap setup is off. Dispatch input is unavailable; lighting still works.")
                    .keymapNote()
                Button("Turn on keymap setup") { Task { await model.allowKeymapSetup() } }
            case let .failed(message):
                Text("Keymap: \(message)").keymapNote()
                Button("Retry keymap check") { Task { await model.retryKeymapCheck() } }
            }
            Button("Restore original keymap") { Task { await model.restoreOriginalKeymap() } }
                .disabled(model.snapshot.phase != .operational)
        }
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Herdr")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.herdrState.availability.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message = model.herdrPanelMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.herdrState.agents.isEmpty {
                Text("No active agents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(agentRows, id: \.index) { row in
                    let agent = row.agent
                    HStack {
                        Text(row.key.map(String.init) ?? "–")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(model.herdrState.label(for: agent, style: model.agentLabelStyle))
                            .lineLimit(1)
                        Spacer()
                        Text(agent.status.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Agents on a slot key, labeled with the key. Without any slot keys the
    /// panel still lists the first few agents.
    private var agentRows: [(index: Int, key: Int?, agent: HerdrAgent)] {
        let rows = model.herdrState.agents.enumerated().map { index, agent in
            (index: index, key: model.slotKeys.key(forAgentAt: index), agent: agent)
        }
        return model.slotKeys.keysBySlot.isEmpty ? Array(rows.prefix(6)) : rows.filter { $0.key != nil }
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Configuration")
                .font(.subheadline.weight(.semibold))
            Text(model.configurationURL.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
            HStack {
                Button("Reveal") { model.revealConfigurationFolder() }
                Button("Reload") {
                    Task { await model.reloadConfiguration() }
                }
            }
        }
    }

    private var statusColor: Color {
        switch model.snapshot.phase {
        case .operational: .green
        case .degraded: .orange
        case .disabled: .secondary
        case .starting, .connecting, .stopping: .blue
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
}

private extension Text {
    /// Panel notes wrap instead of truncating; the consent text in particular
    /// must be readable in full before the user agrees to a keymap write.
    func keymapNote() -> some View {
        font(.caption).fixedSize(horizontal: false, vertical: true)
    }
}
