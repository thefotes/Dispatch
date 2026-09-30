import AppKit
import Combine
import DispatchCore
import DispatchCreatorMicro
import DispatchMacOS
import DispatchProviders
import DispatchRuntime
import Foundation

@MainActor
final class AppModel: ObservableObject {
    enum KeymapStatus: Equatable {
        case waitingForPad, consentNeeded, checking, ready, changed, disabled, failed(String)

        /// The status once the runtime reports `snapshot`. The keymap is
        /// checked each time the pad connects, so while it is not connected
        /// only the user's choice to turn keymap setup off still applies.
        func afterRuntimeChange(to snapshot: RuntimeSnapshot) -> KeymapStatus {
            let padConnected = switch snapshot.phase {
            case .operational: true
            // A device issue means the pad is gone. Any other issue leaves
            // the pad as it was: connected while running, or not yet
            // connected after a configuration error at launch.
            case .degraded: if case .device = snapshot.issue { false } else { self != .waitingForPad }
            case .disabled, .starting, .connecting, .stopping: false
            }
            return padConnected || self == .disabled ? self : .waitingForPad
        }
    }

    @Published private(set) var keymapStatus = KeymapStatus.waitingForPad
    @Published private(set) var snapshot = RuntimeSnapshot.disabled
    @Published private(set) var herdrState = HerdrState.disconnected
    @Published private(set) var accessibilityPermission = AccessibilityPermission.denied
    @Published private(set) var inputMonitoringPermission = InputMonitoringPermission.denied
    @Published private(set) var agentLabelStyle = AgentLabelStyle.workspaceAndAgent
    @Published private(set) var slotKeys = HerdrSlotKeys(DefaultConfiguration.value)

    let configurationURL = FileConfigurationLoader.defaultURL
    private let herdrSocketURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/herdr/herdr.sock")

    private let runtime: DispatchRuntime
    private let pad: CreatorMicroDriver
    private let keymapPreference: KeymapSetupPreference
    private let herdr: HerdrAdapter
    private let automation: SystemMacOSAutomation
    private let tunnels: SSHHerdrTunnels
    private let terminalConfigurationSource: HerdrTerminalConfigurationSource
    private let inputMonitoringRequester: any InputMonitoringPermissionRequesting
    private let herdrPollInterval: Duration
    private let presentationRenderer = HerdrPresentationRenderer()
    private var snapshotTask: Task<Void, Never>?
    private var herdrStateTask: Task<Void, Never>?
    private var herdrPollTask: Task<Void, Never>?

    var isEnabled: Bool {
        snapshot.phase != .disabled && snapshot.phase != .stopping
    }

    var statusTitle: String {
        switch snapshot.phase {
        case .disabled: "Off"
        case .starting: "Starting"
        case .connecting: "Connecting to pad"
        case .operational: "Connected"
        case .degraded: "Needs attention"
        case .stopping: "Stopping"
        }
    }

    var statusSymbol: String {
        switch snapshot.phase {
        case .operational: "circle.grid.3x3.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .starting, .connecting, .stopping: "arrow.triangle.2.circlepath"
        case .disabled: "circle.grid.3x3"
        }
    }

    var issueDescription: String? {
        switch snapshot.issue {
        case let .configuration(message): "Configuration: \(message)"
        case let .device(message): "Creator Micro: \(message)"
        case let .action(id, message): "\(id.rawValue): \(message)"
        case let .presentation(message): "Lighting: \(message)"
        case nil: nil
        }
    }

    var herdrPanelMessage: String? {
        HerdrPanelMessage.message(
            for: herdrState,
            socketExists: FileManager.default.fileExists(atPath: herdrSocketURL.path)
        )
    }

    init(
        inputMonitoringRequester: any InputMonitoringPermissionRequesting =
            IOHIDInputMonitoringPermissionRequester(),
        defaults: UserDefaults = .standard,
        tunnels providedTunnels: SSHHerdrTunnels? = nil,
        herdr providedHerdr: HerdrAdapter? = nil,
        runtime providedRuntime: DispatchRuntime? = nil,
        herdrPollInterval: Duration = .seconds(2.5)
    ) {
        self.inputMonitoringRequester = inputMonitoringRequester
        self.herdrPollInterval = herdrPollInterval
        let keymapPreference = KeymapSetupPreference(defaults: defaults)
        self.keymapPreference = keymapPreference
        let transport = IOHIDCreatorMicroTransport()
        let pad = CreatorMicroDriver(
            transport: transport,
            identity: DeviceIdentity(rawValue: "creator-micro-2")
        )
        let automation = SystemMacOSAutomation()
        let tunnels = providedTunnels ?? SSHHerdrTunnels()
        let terminalConfigurationSource = HerdrTerminalConfigurationSource()
        let herdr = providedHerdr ?? HerdrAdapter(
            client: HerdrSelectedMachineConnection(
                local: HerdrUnixSocketClient(configuration: .init(socketPath: herdrSocketURL.path)),
                selection: HerdrClientSelection(directory: HerdrClientSelection.defaultDirectory),
                tunnels: tunnels
            ),
            encoder: HerdrProtocol22Codec(),
            navigator: KeyboardHerdrClientNavigator(
                automation: automation,
                settings: { await terminalConfigurationSource.settings() }
            ),
            slotPriority: HerdrPresentationRenderer.defaultPalette.ambientPriority
        )
        let registrations = HerdrActions.registrations(controller: herdr)
            + MacOSActions.registrations(automation: automation)
        guard let runtime = providedRuntime ?? (try? DispatchRuntime(
            pad: pad,
            registrations: registrations,
            configurationLoader: ValidatingConfigurationLoader(
                file: FileConfigurationLoader(fallback: DefaultConfiguration.value)
            )
        )) else {
            preconditionFailure("Dispatch contains duplicate or invalid built-in action definitions.")
        }
        self.runtime = runtime
        self.pad = pad
        self.herdr = herdr
        self.automation = automation
        self.tunnels = tunnels
        self.terminalConfigurationSource = terminalConfigurationSource
    }

    deinit {
        snapshotTask?.cancel()
        herdrStateTask?.cancel()
        herdrPollTask?.cancel()
    }

    func start() async {
        Log.logger.info("Dispatch is starting.")
        await terminalConfigurationSource.attach(runtime)
        beginObservingIfNeeded()
        beginHerdrPollingIfNeeded()
        accessibilityPermission = await automation.accessibilityPermission(promptIfNeeded: false)
        await refreshInputMonitoringPermission()
        await runtime.start()
    }

    func stop() async {
        Log.logger.info("Dispatch is stopping.")
        let pollTask = herdrPollTask
        herdrPollTask = nil
        pollTask?.cancel()
        await pollTask?.value
        await runtime.stop()
        await tunnels.closeAll()
    }

    func toggleEnabled() async {
        if isEnabled {
            await stop()
        } else {
            await start()
        }
    }

    func reloadConfiguration() async {
        await runtime.reloadConfiguration()
    }

    func allowKeymapSetup() async {
        keymapPreference.setAllowed(true)
        await applyKeymap()
    }

    func retryKeymapCheck() async {
        await checkKeymap()
    }

    func applyKeymap() async {
        guard snapshot.phase == .operational else { return }
        keymapStatus = .checking
        await pad.setInputEnabled(false)
        do {
            try await pad.prepareKeymap()
            await pad.setInputEnabled(true)
            keymapStatus = .ready
        } catch {
            keymapStatus = .failed(String(describing: error))
        }
    }

    func keepCurrentKeymap() async {
        keymapPreference.setAllowed(false)
        await pad.setInputEnabled(false)
        keymapStatus = .disabled
    }

    func restoreOriginalKeymap() async {
        guard snapshot.phase == .operational else { return }
        keymapStatus = .checking
        await pad.setInputEnabled(false)
        do {
            try await pad.restoreKeymap()
            keymapPreference.setAllowed(false)
            keymapStatus = .disabled
        } catch {
            keymapStatus = .failed(String(describing: error))
        }
    }

    private func checkKeymap() async {
        await pad.setInputEnabled(false)
        keymapStatus = .checking
        do {
            let status = try await keymapPreference.statusAfterConnecting {
                try await pad.keymapState()
            }
            switch status {
            case .ready:
                await pad.setInputEnabled(true)
                keymapStatus = .ready
            default:
                keymapStatus = status
            }
        } catch {
            keymapStatus = .failed(String(describing: error))
        }
    }

    func requestAccessibilityPermission() async {
        accessibilityPermission = await automation.accessibilityPermission(promptIfNeeded: true)
    }

    /// Re-reads the grant without prompting. The pad connection raises the
    /// system prompt itself, and the user may grant access in System Settings
    /// at any time, so the panel checks again whenever it opens.
    func refreshInputMonitoringPermission() async {
        inputMonitoringPermission = await inputMonitoringRequester.check()
    }

    /// Prompts for Input Monitoring only when the grant is missing, mirroring
    /// how the Accessibility flow works.
    func requestInputMonitoringPermission() async {
        inputMonitoringPermission = await inputMonitoringRequester.requestIfNeeded()
    }

    private static let inputMonitoringSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    )

    func openInputMonitoringSettings() {
        guard let url = Self.inputMonitoringSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    func revealConfigurationFolder() {
        NSWorkspace.shared.open(configurationURL.deletingLastPathComponent())
    }

    func shutDownAndQuit() async {
        await stop()
        NSApplication.shared.terminate(nil)
    }

    private func beginObservingIfNeeded() {
        if snapshotTask == nil {
            let snapshots = runtime.snapshots
            snapshotTask = Task { [weak self] in
                for await snapshot in snapshots {
                    guard !Task.isCancelled else { return }
                    let wasOperational = self?.snapshot.phase == .operational
                    self?.snapshot = snapshot
                    if let status = self?.keymapStatus.afterRuntimeChange(to: snapshot) {
                        self?.keymapStatus = status
                    }
                    await self?.refreshPanelSettings()
                    await self?.refreshSlotPriority()
                    if snapshot.phase == .operational {
                        if wasOperational != true { await self?.checkKeymap() }
                        await self?.refreshPresentation()
                    }
                }
            }
        }
        if herdrStateTask == nil {
            herdrStateTask = Task { [weak self, herdr] in
                let states = await herdr.states()
                for await state in states {
                    guard !Task.isCancelled else { return }
                    self?.herdrState = state
                    // Not only while operational: a failed action or
                    // lighting write leaves the runtime degraded, and the
                    // lights must keep following Herdr. The runtime ignores
                    // lighting while the pad is not running, and Herdr only
                    // publishes changed states, so this cannot loop.
                    await self?.refreshPresentation()
                }
            }
        }
    }

    private func beginHerdrPollingIfNeeded() {
        guard herdrPollTask == nil else { return }
        herdrPollTask = Task { [herdr, herdrPollInterval] in
            while !Task.isCancelled {
                try? await herdr.refresh()
                try? await Task.sleep(for: herdrPollInterval)
            }
        }
    }

    private func refreshPanelSettings() async {
        let configuration = await runtime.currentConfiguration()
        agentLabelStyle = configuration?.agentLabel ?? .workspaceAndAgent
        slotKeys = HerdrSlotKeys(configuration ?? DefaultConfiguration.value)
    }

    /// Keys light and focus agents by the same status priority that picks
    /// the ambient light.
    private func refreshSlotPriority() async {
        let palette = await runtime.currentConfiguration()?.statusPalette
            ?? HerdrPresentationRenderer.defaultPalette
        await herdr.setSlotPriority(palette.ambientPriority)
    }

    private func refreshPresentation() async {
        let configuration = await runtime.currentConfiguration() ?? DefaultConfiguration.value
        await runtime.apply(presentationRenderer.render(herdrState, configuration: configuration))
    }
}
