import AppKit
import SwiftUI
import WLKit

/// A window showing the virtual pad: the lights the bridge is driving, and
/// keys you can press back at it.
///
/// It is a plain resizable window rather than one of the floating panels,
/// because unlike the stack or land views this one is meant to be clicked, sat
/// beside your editor, and left open.
@MainActor
final class EmulatorWindowController: NSObject, NSWindowDelegate {
    static let shared = EmulatorWindowController()

    private var window: NSWindow?

    func show(_ emulator: PadEmulator) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Creator Micro 2 — emulated"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.contentView = NSHostingView(rootView: EmulatorView(emulator: emulator))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

struct EmulatorView: View {
    @ObservedObject var emulator: PadEmulator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            pad
            Divider()
            controls
            Divider()
            traffic
        }
        .padding(16)
        .frame(minWidth: 340, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - The pad

    private var pad: some View {
        VStack(spacing: 8) {
            // The ambient ring, which the bridge drives with the worst state
            // across every agent.
            RoundedRectangle(cornerRadius: 14)
                .fill(zoneColor(emulator.ambientZone))
                .frame(height: 8)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))

            VStack(spacing: 6) {
                ForEach(Array(Pad.displayRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 6) {
                        ForEach(row, id: \.self) { key in keyButton(key) }
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.82)))

            HStack(spacing: 10) {
                stepper("Dial", down: Pad.dialDownID, up: Pad.dialUpID)
                Spacer(minLength: 0)
                joystick
            }
        }
    }

    private func keyButton(_ key: Int) -> some View {
        let state = emulator.keys[key]
        let lit = state?.isLit == true && emulator.bound.contains(key)
        return Button {
            emulator.press(key)
        } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(lit ? Color(packedRGB: state?.color ?? 0)
                          : Color.white.opacity(emulator.bound.contains(key) ? 0.10 : 0.04))
                .frame(width: 52, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                )
                .overlay(
                    Text("\(key)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(lit ? .black.opacity(0.55) : .white.opacity(0.35))
                        .padding(3),
                    alignment: .topLeading
                )
        }
        .buttonStyle(.plain)
        .help(helpText(key))
    }

    private func helpText(_ key: Int) -> String {
        guard emulator.bound.contains(key) else {
            return "Key \(key) — not bound to KV_OAI_AG*, so it sends a keystroke and cannot light"
        }
        guard let state = emulator.keys[key], state.isLit else { return "Key \(key) — dark" }
        return "Key \(key) — \(hexString(state.color)), \(state.effect.label.lowercased())"
    }

    private var joystick: some View {
        VStack(spacing: 3) {
            arrow("chevron.up", Pad.joyNorthID)
            HStack(spacing: 3) {
                arrow("chevron.left", Pad.joyWestID)
                Circle().fill(Color.secondary.opacity(0.18)).frame(width: 22, height: 22)
                arrow("chevron.right", Pad.joyEastID)
            }
            arrow("chevron.down", Pad.joySouthID)
        }
    }

    private func arrow(_ symbol: String, _ key: Int) -> some View {
        Button { emulator.press(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .help("Joystick — key \(key)")
    }

    private func stepper(_ label: String, down: Int, up: Int) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Button { emulator.press(down) } label: { Image(systemName: "minus") }
                .buttonStyle(.bordered).help("Counter-clockwise — key \(down)")
            Button { emulator.press(up) } label: { Image(systemName: "plus") }
                .buttonStyle(.bordered).help("Clockwise — key \(up)")
        }
    }

    private func zoneColor(_ zone: OAI.Zone) -> Color {
        guard zone.effect != .off, zone.brightness > 0 else { return Color.white.opacity(0.06) }
        return Color(packedRGB: zone.color)
    }

    // MARK: - Below the pad

    private var controls: some View {
        HStack {
            Label(
                emulator.bound.isEmpty
                    ? "Stock keymap — no key can light yet"
                    : "\(emulator.bound.count) keys bound to KV_OAI_AG*",
                systemImage: emulator.bound.isEmpty ? "exclamationmark.triangle" : "checkmark.circle"
            )
            .font(.caption)
            .foregroundStyle(emulator.bound.isEmpty ? .orange : .secondary)
            Spacer()
            Button("Reset") { emulator.reset() }
                .help("Back to a factory pad: stock keymap, every light off")
        }
    }

    private var traffic: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TRAFFIC")
                .font(.system(.caption2, design: .monospaced)).bold()
                .foregroundStyle(.tertiary).kerning(1.1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(emulator.traffic.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }
                .onChange(of: emulator.traffic.count) { count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
            .frame(minHeight: 90)
        }
    }
}
