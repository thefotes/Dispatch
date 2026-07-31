import SwiftUI
import AppKit
import ServiceManagement
import WLKit

struct MenuPanelView: View {
    @EnvironmentObject var bridge: BridgeController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if bridge.permissionDenied {
                permissionBanner
            } else if bridge.isRunning {
                padSection
                Divider()
                agentSection
            } else {
                idleHint
            }

            if let error = bridge.lastError, !bridge.permissionDenied {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }

            if bridge.contendingClient {
                Divider()
                Label(
                    "Another app is also driving this pad — colours may fight.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 8)
            }

            Divider()
            footer
        }
        .frame(width: 300)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Micro Manager").font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { bridge.isRunning },
                set: { on in
                    BridgeSettings.enabled = on
                    Task { await bridge.toggle() }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(bridge.isRunning ? "Turn off" : "Turn on")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var subtitle: String {
        guard bridge.isRunning else { return "Off" }
        guard bridge.deviceConnected else { return "Looking for the pad…" }
        var parts = [bridge.deviceName, bridge.firmware]
        if let battery = bridge.battery { parts.append(battery) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Pad

    private var padSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Pad.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { key in keyView(key) }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func keyView(_ index: Int) -> some View {
        let color = bridge.keyColors[index]
        let isBound = Pad.boundKeyIDs.contains(index)
        let isStackKey = index == Pad.stackKeyID
        let isTabCycleKey = index == Pad.tabCycleKeyID
        // Only agent keys index into the agent list; the stack key sits at 6,
        // which is a perfectly valid agent index and would be the wrong agent.
        let agent = Pad.agentKeyIDs.contains(index) && index < bridge.agents.count
            ? bridge.agents[index]
            : nil

        return Button {
            if isStackKey {
                StackPanelController.shared.toggle()
            } else if isTabCycleKey {
                Task { await bridge.cycleTabs() }
            } else if agent != nil {
                Task { await bridge.focusSlot(index) }
            }
        } label: {
            RoundedRectangle(cornerRadius: 5)
                .fill(color ?? Color.secondary.opacity(isBound ? 0.16 : 0.07))
                .frame(width: 34, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(agent == nil && !isStackKey && !isTabCycleKey)
        .help(helpText(index, agent: agent, isStackKey: isStackKey, isTabCycleKey: isTabCycleKey))
    }

    private func helpText(_ index: Int, agent: HerdrAgent?, isStackKey: Bool, isTabCycleKey: Bool) -> String {
        if isStackKey { return "GitButler stack for the focused agent" }
        if isTabCycleKey { return "Cycle tabs in the focused Herdr window" }
        if let agent { return "\(agent.shortName) — \(agent.status)" }
        return "Key \(index)"
    }

    // MARK: - Agents

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if bridge.agents.isEmpty {
                Text("No agents running")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            } else {
                ForEach(Array(bridge.agents.prefix(Pad.agentKeyIDs.count).enumerated()), id: \.offset) { index, agent in
                    Button {
                        Task { await bridge.focusSlot(index) }
                    } label: {
                        HStack(spacing: 9) {
                            Circle()
                                .fill(bridge.keyColors[index] ?? Color.secondary.opacity(0.3))
                                .frame(width: 9, height: 9)
                            Text("\(index)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(agent.shortName).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(agent.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 14).padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Other states

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Input Monitoring is needed", systemImage: "lock.fill")
                .font(.callout).bold()
            Text("macOS blocks access to the pad until this app is allowed to monitor input.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var idleHint: some View {
        Text("Switch on to light each agent on its own key.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.vertical, 12)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Open at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .padding(.horizontal, 14).padding(.top, 8)
                .onChange(of: launchAtLogin) { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        // Registering only works from a bundled, signed app;
                        // reflect reality rather than leaving the box ticked.
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            HStack {
                Button("Refresh") { Task { await bridge.forceRepaint() } }
                    .disabled(!bridge.isRunning)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}
