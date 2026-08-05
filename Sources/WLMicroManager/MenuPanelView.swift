import SwiftUI
import AppKit
import ServiceManagement
import WLKit

struct MenuPanelView: View {
    @EnvironmentObject var bridge: BridgeController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var inspectorError: String?

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
            ForEach(Array(Pad.displayRows.enumerated()), id: \.offset) { _, row in
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
        let isLandKey = index == Pad.landKeyID
        let macroText = bridge.keyBindings.text(for: index)
        let isVoiceKey = macroText == nil && Pad.voiceKeyIDs.contains(index)
        // Key index and agent slot are different orderings — the top row is
        // wired right to left — so the slot lookup goes through the pad map.
        let slot = Pad.agentSlot(for: index)
        let agent = slot.flatMap { $0 < bridge.agents.count ? bridge.agents[$0] : nil }

        return Button {
            if isStackKey {
                StackPanelController.shared.toggle()
            } else if isTabCycleKey {
                Task { await bridge.cycleTabs() }
            } else if isLandKey {
                LandPanelController.shared.handleLandKey()
            } else if let macroText {
                Task { await bridge.injectPrompt(macroText) }
            } else if isVoiceKey {
                VoiceController.shared.handleVoiceKey()
            } else if let slot, agent != nil {
                Task { await bridge.focusSlot(slot) }
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
        .disabled(agent == nil && !isStackKey && !isTabCycleKey && !isLandKey
                  && macroText == nil && !isVoiceKey)
        .help(helpText(index, agent: agent, isStackKey: isStackKey,
                       isTabCycleKey: isTabCycleKey, isLandKey: isLandKey,
                       macroText: macroText, isVoiceKey: isVoiceKey))
    }

    private func helpText(
        _ index: Int,
        agent: HerdrAgent?,
        isStackKey: Bool,
        isTabCycleKey: Bool,
        isLandKey: Bool,
        macroText: String?,
        isVoiceKey: Bool
    ) -> String {
        if isStackKey { return "GitButler stack for the focused agent" }
        if isTabCycleKey { return "Cycle tabs in the focused Herdr window" }
        if isLandKey { return "Land the focused agent's branches onto the target" }
        if let macroText { return "Type: \(macroText)" }
        if isVoiceKey { return "Voice input for the focused agent" }
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
                                .fill(bridge.keyColors[Pad.agentKeyIDs[index]] ?? Color.secondary.opacity(0.3))
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

            Toggle("Emulate the pad", isOn: Binding(
                get: { bridge.emulator != nil },
                set: { on in
                    BridgeSettings.emulate = on
                    Task {
                        await bridge.useEmulator(on)
                        if let emulator = bridge.emulator {
                            EmulatorWindowController.shared.show(emulator)
                        } else {
                            EmulatorWindowController.shared.close()
                        }
                    }
                }
            ))
            .toggleStyle(.checkbox)
            .padding(.horizontal, 14).padding(.top, 4)
            .help("Drive a virtual pad instead of the hardware")

            if let inspectorError {
                Text(inspectorError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.top, 6)
            }

            HStack {
                Button("Refresh") { Task { await bridge.forceRepaint() } }
                    .disabled(!bridge.isRunning)
                Button("Inspector") {
                    inspectorError = nil
                    InspectorLauncher.launch { inspectorError = $0 }
                }
                .help("Watch the traffic to and from the pad, and drive its lighting by hand")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}
