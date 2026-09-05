import SwiftUI
import AppKit
import WLKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock icon, no app-switcher entry. The bundled app
        // also sets LSUIElement; this covers `swift run` during development.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Only does anything when config.json's "provider" is a `"launch"`
        // spec — otherwise there is no subprocess to clean up.
        ProviderFactory.terminateLaunchedProcess()
    }
}

@main
struct MicroManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var bridge: BridgeController

    init() {
        // The provider is a constructor argument, not something `start()`
        // re-reads — has to be decided before the bridge exists.
        _bridge = StateObject(wrappedValue: BridgeController(provider: ProviderFactory.make()))
    }

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

                    let shortcuts = ShortcutController.shared
                    shortcuts.onError = { [weak bridge] message in
                        bridge?.noteError(message)
                    }
                    bridge.onShortcut = { spec in shortcuts.post(spec) }

                    let tune = TuneController.shared
                    tune.onError = { [weak bridge] message in
                        bridge?.noteError(message)
                    }
                    tune.bindings = { [weak bridge] in
                        bridge?.keyBindings ?? KeyBindings()
                    }
                    // `resolvedDialMode` (see its doc in BridgeController)
                    // is set once the provider's describe() lands in
                    // start(), so a config edit takes effect on the next
                    // off/on toggle.
                    bridge.onDial = { [weak bridge] step in
                        guard let bridge else { return }
                        if bridge.resolvedDialMode == nil {
                            tune.handleDial(step)
                        } else {
                            Task { await bridge.cycleDial(step) }
                        }
                    }
                    // Same split as the dial: a provider that offers
                    // joystick navigation (Herdr's pane-by-pane focus)
                    // owns the joystick; otherwise the app keeps its own
                    // model-cycling behaviour.
                    bridge.onJoystick = { [weak bridge] direction in
                        guard let bridge else { return }
                        if bridge.joystickNavigation {
                            Task { await bridge.moveJoystick(direction) }
                        } else {
                            tune.handleJoystick(direction)
                        }
                    }
                    // While a land confirmation is up, every key that is not
                    // the land key means "cancel", nothing else.
                    bridge.onKeyIntercept = { index in
                        guard index != Pad.landKeyID else { return false }
                        return land.handleOtherKey()
                    }

                    // Choose the transport before starting: `useEmulator`
                    // rebuilds the device, so doing it after would tear down a
                    // connection we just made.
                    await bridge.useEmulator(BridgeSettings.emulate)

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

    private static let emulateKey = "emulatePad"

    /// Drive a virtual pad instead of the hardware. `WL_EMULATE=1` forces it on
    /// for a single run, which is what makes `swift run` useful with no device
    /// plugged in.
    static var emulate: Bool {
        get {
            if ProcessInfo.processInfo.environment["WL_EMULATE"] == "1" { return true }
            return UserDefaults.standard.bool(forKey: emulateKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: emulateKey) }
    }
}
