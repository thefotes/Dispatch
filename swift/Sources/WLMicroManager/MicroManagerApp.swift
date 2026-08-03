import SwiftUI
import AppKit
import WLKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no app-switcher entry. The bundled app
        // also sets LSUIElement; this covers `swift run` during development.
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

@main
struct MicroManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var bridge = BridgeController()

    var body: some Scene {
        MenuBarExtra {
            MenuPanelView()
                .environmentObject(bridge)
                .task {
                    // The stack and land keys open windows, which the bridge
                    // knows nothing about, so the two are joined here.
                    let stack = StackPanelController.shared
                    stack.onVisibilityChange = { [weak bridge] open in
                        Task { await bridge?.setStackPanelOpen(open) }
                    }
                    bridge.onStackKey = { stack.toggle() }

                    let land = LandPanelController.shared
                    land.onVisibilityChange = { [weak bridge] open in
                        Task { await bridge?.setLandPanelOpen(open) }
                    }
                    bridge.onLandKey = { land.handleLandKey() }

                    let voice = VoiceController.shared
                    voice.onActiveChange = { [weak bridge] active in
                        Task { await bridge?.setVoiceActive(active) }
                    }
                    voice.onError = { [weak bridge] message in
                        bridge?.noteError(message)
                    }
                    bridge.onVoiceKey = { voice.handleVoiceKey() }

                    let tune = TuneController.shared
                    tune.onError = { [weak bridge] message in
                        bridge?.noteError(message)
                    }
                    tune.bindings = { [weak bridge] in
                        bridge?.keyBindings ?? KeyBindings()
                    }
                    bridge.onDial = { step in tune.handleDial(step) }
                    bridge.onJoystick = { direction in tune.handleJoystick(direction) }
                    // While a land confirmation is up, every key that is not
                    // the land key means "cancel", nothing else.
                    bridge.onKeyIntercept = { index in
                        guard index != Pad.landKeyID else { return false }
                        return land.handleOtherKey()
                    }

                    // Come back up in whatever state it was left in, so a
                    // login-item launch resumes rather than sitting idle.
                    // Defaults to on for a first run.
                    if BridgeSettings.enabled, !bridge.isRunning {
                        await bridge.start()
                    }
                }
        } label: {
            Image(nsImage: MenuBarIcon.image(for: MenuBarIcon.State.from(bridge)))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Persisted across launches.
enum BridgeSettings {
    private static let key = "bridgeEnabled"

    static var enabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: key) == nil { return true }
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
