import Foundation
import SwiftUI
import IOKit
import IOKit.hid

/// Drives the pad from Herdr agent status: each agent gets its own key, and the
/// underglow carries a worst-state-wins aggregate.
///
/// Liveness comes from three places, so a missed event can never leave the pad
/// showing something stale:
///   1. a lifecycle stream (panes appearing, disappearing, gaining agents)
///   2. one status stream per agent pane (instant transitions)
///   3. a slow poll of `agent.list` as a backstop
///
/// `agent.list` is always the source of truth; events only decide *when* to
/// look. This is a port of `bin/leds.js` — including the parts that were bug
/// fixes, which are called out where they matter.
@MainActor
public final class BridgeController: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var isRunning = false
    @Published public private(set) var deviceConnected = false
    @Published public private(set) var keymapReady = false
    @Published public private(set) var permissionDenied = false
    @Published public private(set) var deviceName = "—"
    @Published public private(set) var firmware = "—"
    @Published public private(set) var battery: String?
    @Published public private(set) var agents: [HerdrAgent] = []
    @Published public private(set) var keyColors: [Int: Color] = [:]
    @Published public private(set) var keyEffects: [Int: OAI.Effect] = [:]
    @Published public private(set) var aggregateState: String?
    @Published public private(set) var lastError: String?
    /// Another process is talking to the same pad. A shared HID open means we
    /// receive its replies too, so a response id we never issued is a reliable
    /// tell.
    @Published public private(set) var contendingClient = false
    /// Whether the GitButler stack is on screen. Only the key light cares —
    /// the panel itself lives in the app layer.
    @Published public private(set) var stackPanelOpen = false
    /// Same for the land window.
    @Published public private(set) var landPanelOpen = false
    /// Whether a Claude voice take is open, for the voice key's light.
    @Published public private(set) var voiceActive = false
    /// The dial modes the current provider offers, for a future settings UI.
    /// Set on every `start()`; never includes `"effort"`.
    @Published public private(set) var dialModes: [ProviderDialMode] = []
    /// `config.json`'s `"dial"` selection, resolved against the current
    /// provider's `dialModes`. nil means "no provider mode" — either
    /// `"effort"` was configured (Micromanager's own reasoning-effort
    /// ladder, the app layer's job, never a provider's), or the configured
    /// name wasn't one this provider actually offers, reported through
    /// `lastError` by `resolveDialSelection`. What `cycleDial` acts on.
    @Published public private(set) var resolvedDialMode: ProviderDialMode?

    public var config: BridgeConfig
    /// Text macros for the spare keys, reloaded on every bridge start so a
    /// config edit only needs an off/on toggle, not a relaunch.
    public private(set) var keyBindings = KeyBindings.load()

    /// Overrides `keyBindings` without going through `start()`'s config-file
    /// reload — tests only, so a binding can be exercised without a real
    /// `config.json` on disk. Call after `start()`, not before: `start()`
    /// reloads from disk itself and would clobber this. Re-resolves the
    /// dial immediately against whatever `dialModes` the provider already
    /// described, so a test doesn't need a second `start()`/`stop()` cycle.
    func setKeyBindingsForTesting(_ bindings: KeyBindings) {
        keyBindings = bindings
        let (resolved, warning) = Self.resolveDialSelection(bindings.dialSelection, offeredBy: dialModes)
        resolvedDialMode = resolved
        if let warning { lastError = warning }
    }

    /// Called when the stack key is pressed. The bridge owns the key, the app
    /// owns the window, so this is where the two meet.
    public var onStackKey: (() -> Void)?
    /// Called when the land key is pressed; same split as `onStackKey`.
    public var onLandKey: (() -> Void)?
    /// Called when either half of the wide voice key is pressed.
    public var onVoiceKey: (() -> Void)?
    /// Called for a key bound to a shortcut, once it has parsed cleanly.
    /// Posting the event is app-layer (needs AppKit and Accessibility).
    public var onShortcut: ((ShortcutSpec) -> Void)?
    /// Called per dial detent: +1 clockwise, -1 counter-clockwise.
    public var onDial: ((Int) -> Void)?
    /// Called when the joystick enters a cardinal sector.
    public var onJoystick: ((Pad.JoystickDirection) -> Void)?
    /// Consulted before any key does its normal job. Returning true consumes
    /// the press — this is how a pending land confirmation turns every other
    /// key into "cancel" without those keys also doing their usual work.
    public var onKeyIntercept: ((Int) -> Bool)?

    // MARK: - Internals

    private var device = WLDevice()
    /// Non-nil while the bridge is driving a virtual pad instead of hardware.
    @Published public private(set) var emulator: PadEmulator?
    /// What agent status, dial navigation, and prompt injection actually run
    /// against. Herdr is one implementation (`HerdrProvider`) behind this;
    /// swapping it for another tool means implementing `Provider`, not
    /// changing anything here.
    private let provider: Provider
    private var providerSubscription: ProviderSubscription?
    private var pollTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var reopenTask: Task<Void, Never>?
    private var lastFingerprint: String?
    private var issuedIDs = Set<Int>()
    private var warnedPermission = false
    /// When the wide key (10/11) last reported a press, for `WideKeyDebounce`
    /// to collapse its two switches' notifications into one logical press.
    private var lastVoiceKeyPress: DispatchTime?

    public init(config: BridgeConfig = BridgeConfig(), provider: Provider = HerdrProvider()) {
        self.config = config
        self.provider = provider
        wire(device)
    }

    /// Swap the hardware for a virtual pad, or back. The device is rebuilt
    /// either way, so the bridge reconnects from scratch rather than trying to
    /// carry state across a transport it no longer has.
    public func useEmulator(_ on: Bool) async {
        guard on != (emulator != nil) else { return }
        let wasRunning = isRunning
        if wasRunning { await stop() }
        let pad = on ? PadEmulator() : nil
        emulator = pad
        device = WLDevice(emulator: pad)
        wire(device)
        if wasRunning { await start() }
    }

    private func wire(_ device: WLDevice) {
        device.onDisconnect = { [weak self] _ in
            guard let self else { return }
            self.deviceConnected = false
            self.lastFingerprint = nil
            if self.isRunning { self.scheduleReopen() }
        }
        device.onTX = { [weak self] _, _, id in
            self?.issuedIDs.insert(id)
        }
        device.onResponse = { [weak self] id, _, _ in
            guard let self else { return }
            // A reply to an id we never sent came from another client.
            if self.issuedIDs.remove(id) == nil { self.contendingClient = true }
        }
        device.onNotification = { [weak self] method, params in
            guard let self, method == OAI.notifyHID else { return }
            guard let dict = params as? [String: Any] else { return }
            guard (dict["act"] as? Int) == 1 else { return }   // press, not release
            guard let index = OAI.agIndex(dict["k"] as? String) else { return }
            self.handleKeyPress(index)
        }
    }

    // MARK: - Lifecycle

    public func toggle() async {
        if isRunning { await stop() } else { await start() }
    }

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        contendingClient = false
        keyBindings = KeyBindings.load()
        // A mistyped "dial" keeps its fallback; say so where the panel shows
        // the bridge's other errors, the same way an unrecognised shortcut does.
        if let warning = keyBindings.dialWarning { lastError = warning }
        await applyProviderDescription()

        await openDevice()
        providerSubscription = provider.subscribe { [weak self] in
            Task { @MainActor in self?.schedule() }
        }
        await refresh()

        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = self.config.pollInterval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                await self.refresh()
            }
        }
    }

    public func stop() async {
        isRunning = false
        pollTask?.cancel(); pollTask = nil
        debounceTask?.cancel(); debounceTask = nil
        reopenTask?.cancel(); reopenTask = nil
        providerSubscription?.cancel(); providerSubscription = nil
        lastFingerprint = nil

        // Switching off clears the lights but deliberately leaves the keymap
        // alone: rebinding is a flash write, and the keys light instantly on
        // the way back in if the bindings are still there.
        if device.isConnected {
            await allLightsOff()
            device.disconnect(reason: nil)
        }
        deviceConnected = false
        keyColors = [:]
        keyEffects = [:]
        aggregateState = nil
        agents = []
    }

    /// Pulls the provider's state palette, priority, and dial-mode labels
    /// into `config` — its lighting vocabulary is the provider's, not a
    /// `BridgeController` default. Re-applied on every `start()`, same as
    /// `keyBindings`, so a provider swap only needs an off/on toggle.
    private func applyProviderDescription() async {
        let description = await provider.describe()
        for (state, style) in description.statePalette {
            config.colors[state] = style.color
            config.effects[state] = style.effect
        }
        if !description.statePriority.isEmpty {
            config.priority = description.statePriority
        }
        dialModes = description.dialModes

        let (resolved, warning) = Self.resolveDialSelection(keyBindings.dialSelection, offeredBy: dialModes)
        resolvedDialMode = resolved
        if let warning { lastError = warning }
    }

    /// What `resolvedDialMode` becomes, pure so it is testable without a
    /// provider. Warns only when a name should have matched and didn't.
    static func resolveDialSelection(
        _ selection: KeyBindings.DialSelection,
        offeredBy modes: [ProviderDialMode]
    ) -> (mode: ProviderDialMode?, warning: String?) {
        guard case .provider(let name) = selection else { return (nil, nil) }
        if let match = modes.first(where: { $0.id == name }) { return (match, nil) }
        let available = modes.isEmpty ? "none" : modes.map(\.id).joined(separator: ", ")
        let warning = "The dial's mode \"\(name)\" isn't offered by this provider (available: \(available)) — keeping the reasoning-effort ladder."
        return (nil, warning)
    }

    // MARK: - Device

    private func openDevice() async {
        // Ask for Input Monitoring explicitly. hidapi-style opens just fail
        // with a privilege violation without ever raising the prompt, which
        // reads as a bug rather than a permission.
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        do {
            try device.connect()
            deviceConnected = true
            permissionDenied = false
            warnedPermission = false
            deviceName = device.info?.product ?? "Work Louder device"
            lastError = nil
        } catch {
            deviceConnected = false
            // Ask the API that knows about the grant rather than reading the
            // error code, which says "not permitted" for a wedged pad too.
            let granted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            switch DeviceOpenFailure.classify(accessGranted: granted, message: error.localizedDescription) {
            case .permissionMissing:
                permissionDenied = true
                if !warnedPermission {
                    warnedPermission = true
                    lastError = DeviceOpenFailure.permissionMissing.message
                }
            case .deviceUnavailable(let underlying):
                permissionDenied = false
                lastError = DeviceOpenFailure.deviceUnavailable(underlying).message
            }
            scheduleReopen()
            return
        }

        if let version = try? await device.callAsync("sys.version"),
           let dict = version as? [String: Any],
           let text = dict["version"] as? String {
            firmware = text
        }
        if let status = try? await device.callAsync("device.status"),
           let dict = status as? [String: Any],
           let percent = dict["battery"] as? Int {
            let charging = (dict["is_charging"] as? Bool) == true
            battery = "\(percent)%\(charging ? " ⚡" : "")"
        }

        await ensureKeymap()
    }

    /// Per-key lighting only works on keys bound to `KV_OAI_AG*` on the active
    /// layer, and nothing reports a mismatch — `v.oai.thstatus` answers
    /// `{"ok":1}` for a key it cannot light. So check rather than assume.
    private func ensureKeymap() async {
        do {
            if config.manageKeymap {
                _ = try await KeymapManager.apply(device)
                keymapReady = true
            } else {
                let cfg = try await KeymapManager.read(device)
                keymapReady = KeymapManager.isAgentKeymapApplied(cfg)
                if !keymapReady {
                    lastError = "The agent keys and the stack key are not bound to KV_OAI_AG00..AG06, so per-key colours will do nothing."
                }
            }
        } catch {
            keymapReady = false
            lastError = "Keymap: \(error.localizedDescription)"
        }
    }

    private func scheduleReopen() {
        guard isRunning, reopenTask == nil else { return }
        reopenTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.isRunning else { return }
                if self.deviceConnected { break }
                await self.openDevice()
                if self.deviceConnected {
                    await self.forceRepaint()
                    break
                }
            }
            self?.reopenTask = nil
        }
    }

    // MARK: - Provider events

    private func schedule() {
        guard debounceTask == nil else { return }
        debounceTask = Task { [weak self] in
            guard let self else { return }
            let delay = self.config.debounce
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.debounceTask = nil
            await self.refresh()
        }
    }

    // MARK: - Repaint

    public func forceRepaint() async {
        lastFingerprint = nil
        await refresh()
    }

    private func refresh() async {
        guard isRunning else { return }

        let fetched: [HerdrAgent]
        do {
            fetched = try await provider.status()
        } catch {
            lastError = error.localizedDescription
            return
        }
        lastError = nil
        agents = fetched

        let state = StatusMapper.aggregate(fetched, config)
        // Every overridable key shares this light: a binding (text or
        // shortcut) wins and paints the generic macro colour; an unbound key
        // falls back to whatever it does by default.
        let flexKeys = Pad.overridableKeyIDs.map { key -> OAI.Thread in
            switch keyBindings.action(for: key) {
            case .text, .shortcut:
                return StatusMapper.macroThread(id: key, config)
            case .off:
                return OAI.Thread(id: key, brightness: 0, effect: .off)
            case nil:
                switch key {
                case Pad.stackKeyID: return StatusMapper.stackThread(open: stackPanelOpen, config)
                case Pad.tabCycleKeyID: return StatusMapper.tabCycleThread(config)
                case Pad.landKeyID: return StatusMapper.landThread(open: landPanelOpen, config)
                default:
                    guard Pad.voiceKeyIDs.contains(key) else {
                        return OAI.Thread(id: key, brightness: 0, effect: .off)
                    }
                    return StatusMapper.voiceThread(id: key, active: voiceActive, config)
                }
            }
        }
        let threads = StatusMapper.threads(for: fetched, config) + flexKeys

        // Fingerprint the whole rendered picture, not just the aggregate, so
        // one agent changing still repaints when the worst state has not.
        let fingerprint = threads.map { thread in
            "\(thread.id):\(thread.color ?? -1):\(thread.effect?.rawValue ?? -1):\(thread.brightness ?? -1)"
        }.joined(separator: "|") + "|agg:\(state ?? "-")"

        publishKeyState(threads)
        aggregateState = state

        guard fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint
        await apply(state: state, threads: threads)
    }

    private func publishKeyState(_ threads: [OAI.Thread]) {
        var colors: [Int: Color] = [:]
        var effects: [Int: OAI.Effect] = [:]
        for thread in threads {
            guard let packed = thread.color, (thread.brightness ?? 0) > 0,
                  let effect = thread.effect, effect != .off else { continue }
            colors[thread.id] = Color(packedRGB: packed)
            effects[thread.id] = effect
        }
        keyColors = colors
        keyEffects = effects
    }

    private func apply(state: String?, threads: [OAI.Thread]) async {
        guard deviceConnected else { return }
        do {
            _ = try await device.callAsync(OAI.methodThreads, params: OAI.threadsParams(threads))
            let zone = StatusMapper.zone(for: state, config) ?? .dark
            _ = try await device.callAsync(
                OAI.methodRGBConfig,
                params: OAI.rgbConfigParams(
                    keys: config.driveBacklight ? zone : .dark,
                    ambient: zone
                )
            )
        } catch {
            lastError = error.localizedDescription
            // A write failure this deep almost always means the HID session
            // itself went bad under us, not that this one call was unlucky —
            // observed after sleep/wake over Bluetooth, where the device
            // stays "open" but every SetReport fails with a wedged-session
            // code (0xE00002E2). Retrying the same call against the same
            // handle every poll never recovers on its own; disconnecting
            // does, since it routes through the same onDisconnect →
            // scheduleReopen path a genuinely lost connection already takes,
            // and reconnecting opens a fresh IOHIDDevice from scratch.
            device.disconnect(reason: error.localizedDescription)
        }
    }

    /// Thread state paints over zone state, so clearing the zones alone leaves
    /// the pad lit. Both have to go.
    private func allLightsOff() async {
        let threads = (0...Pad.maxThreadID).map {
            OAI.Thread(id: $0, brightness: 0, effect: .off, syncKeys: false, syncAmbient: false)
        }
        _ = try? await device.callAsync(OAI.methodThreads, params: OAI.threadsParams(threads))
        _ = try? await device.callAsync(
            OAI.methodRGBConfig,
            params: OAI.rgbConfigParams(keys: .dark, ambient: .dark)
        )
    }

    // MARK: - Key presses

    /// Every bound key arrives here. Which key does what is the one place that
    /// has to agree with `Pad`, so keep the dispatch in a single switch.
    public func handleKeyPress(_ index: Int) {
        if onKeyIntercept?(index) == true { return }
        if Pad.voiceKeyIDs.contains(index) {
            let now = DispatchTime.now()
            defer { lastVoiceKeyPress = now }
            if let last = lastVoiceKeyPress, WideKeyDebounce.isSamePress(last, now) { return }
        }
        // A config binding wins over any of these keys' built-in role — this
        // is how the config file may repurpose stack, tabs, land, the macro
        // keys, or the wide voice key.
        if Pad.overridableKeyIDs.contains(index), let action = keyBindings.action(for: index) {
            perform(action)
            return
        }
        if index == Pad.stackKeyID {
            onStackKey?()
        } else if index == Pad.tabCycleKeyID {
            Task { await cycleTabs() }
        } else if index == Pad.landKeyID {
            onLandKey?()
        } else if Pad.voiceKeyIDs.contains(index) {
            onVoiceKey?()
        } else if index == Pad.dialUpID || index == Pad.dialDownID {
            onDial?(index == Pad.dialUpID ? 1 : -1)
        } else if let direction = Pad.JoystickDirection(keyID: index) {
            onJoystick?(direction)
        } else if let slot = Pad.agentSlot(for: index) {
            Task { await focusSlot(slot) }
        }
    }

    /// Runs a key's bound action. A shortcut is validated here rather than at
    /// config-load time, so a typo surfaces as a panel error on the press that
    /// hits it, not a silently dropped binding.
    private func perform(_ action: KeyBindings.KeyAction) {
        switch action {
        case .off:
            break   // explicitly inert — beats the built-in job on purpose
        case .text(let text):
            Task { await injectPrompt(text) }
        case .shortcut(let spec):
            guard let parsed = ShortcutSpec.parse(spec) else {
                lastError = "Unrecognised shortcut \"\(spec)\"."
                return
            }
            onShortcut?(parsed)
        }
    }

    /// Types a macro string into the focused agent's prompt, unsubmitted —
    /// the human still reads it and presses enter.
    public func injectPrompt(_ text: String) async {
        do {
            try await provider.inject(text)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Repaints the voice key. Same contract as `setStackPanelOpen`.
    public func setVoiceActive(_ active: Bool) async {
        guard voiceActive != active else { return }
        voiceActive = active
        await forceRepaint()
    }

    /// Lets app-layer features that fail outside the bridge surface their
    /// error where the menu already shows the bridge's own.
    public func noteError(_ message: String) {
        lastError = message
    }

    /// Advances the focused workspace to its next tab, wrapping.
    public func cycleTabs() async {
        do {
            try await provider.dial(1, mode: "tab")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The dial as a provider navigator: acts on `resolvedDialMode` (see its
    /// doc — this is never called for `.effort`). `step` is +1 / -1 from the
    /// encoder detents. Whether the mode brings the host app forward is the
    /// provider's own call (`ProviderDialMode.raisesHost`), not a name this
    /// file recognises.
    ///
    /// A fast turn fires one unstructured task per detent, and two overlapping
    /// round-trips can both snapshot the same "currently focused" entity
    /// before either focus call lands — several detents net one step, and
    /// whichever response lands last wins. Chaining onto the previous task
    /// serialises the steps, so each sees the state the last one produced.
    private var dialChain: Task<Void, Never>?

    public func cycleDial(_ step: Int) async {
        guard let target = resolvedDialMode else { return }
        let previous = dialChain ?? Task {}
        let task = Task { [weak self] in
            await previous.value
            await self?.runDial(step, target: target)
        }
        dialChain = task
        await task.value
    }

    private func runDial(_ step: Int, target: ProviderDialMode) async {
        do {
            try await provider.dial(step, mode: target.id)
            if target.raisesHost { raiseTerminal() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Focuses an entity and brings the terminal forward — the one
    /// error-and-raise shape every always-raising navigation entry point
    /// shares, so a future one cannot forget the raise.
    private func focusAndRaise(_ body: () async throws -> Void) async {
        do {
            try await body()
            raiseTerminal()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Repaints the stack key. Called by the app when the window opens or
    /// closes, so the key reflects what is actually on screen.
    public func setStackPanelOpen(_ open: Bool) async {
        guard stackPanelOpen != open else { return }
        stackPanelOpen = open
        await forceRepaint()
    }

    /// Repaints the land key. Same contract as `setStackPanelOpen`.
    public func setLandPanelOpen(_ open: Bool) async {
        guard landPanelOpen != open else { return }
        landPanelOpen = open
        await forceRepaint()
    }

    /// Slot N is the Nth key in reading order (`Pad.agentKeyIDs[N]`) — the
    /// same mapping the lighting uses, which is what makes the key you look at
    /// the key you press.
    ///
    /// Herdr selects the pane but leaves the terminal wherever it was in the
    /// window order, so an agent key pressed from a browser used to move a
    /// cursor you could not see. The terminal comes forward with it.
    public func focusSlot(_ index: Int) async {
        guard index >= 0, index < agents.count else { return }
        guard let target = agents[index].focusTarget else { return }
        await focusAndRaise {
            try await provider.focus(target)
        }
    }

    /// The app Herdr's panes live in. Override with `WL_TERMINAL_BUNDLE_ID` if
    /// they live somewhere other than Ghostty.
    public static let defaultTerminalBundleID = "com.mitchellh.ghostty"

    /// Brings the terminal forward unless it is already the active app.
    ///
    /// Nothing is ever launched: the agent whose key was pressed is running in
    /// a pane of a terminal that is by definition already up, so a terminal
    /// that is not running means the bundle id is wrong, and opening a fresh
    /// window would not be what the key meant. macOS may refuse a background
    /// app's `activate` outright, which is what the second attempt is for —
    /// `openApplication` on an already-running app raises it the way `open -a`
    /// does.
    private func raiseTerminal() {
        let identifier = ProcessInfo.processInfo.environment["WL_TERMINAL_BUNDLE_ID"]
            .flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultTerminalBundleID
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier).first
        else { return }
        guard !app.isActive else { return }
        if app.activate(options: []) { return }
        guard let url = app.bundleURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
