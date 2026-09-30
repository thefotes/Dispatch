import DispatchCore
import DispatchMacOS
import DispatchProviders
import DispatchRuntime
import Foundation

/// App-owned interpretation of the integration settings in config.json.
struct HerdrTerminalConfiguration: Sendable {
    static let defaultBundleIdentifier = "com.mitchellh.ghostty"

    static let defaults = HerdrTerminalConfiguration(
        bundleIdentifier: defaultBundleIdentifier,
        windowKeys: HerdrWindowKeys()
    )

    let bundleIdentifier: String
    let windowKeys: HerdrWindowKeys

    private init(bundleIdentifier: String, windowKeys: HerdrWindowKeys) {
        self.bundleIdentifier = bundleIdentifier
        self.windowKeys = windowKeys
    }

    init(_ configuration: DispatchConfiguration) throws {
        let integrations = configuration.integrations ?? [:]
        if let unknown = integrations.keys.first(where: { $0 != "herdr" }) {
            throw AppConfigurationError(path: "integrations.\(unknown)", reason: "Unknown integration.")
        }
        guard let herdr = integrations["herdr"] else {
            bundleIdentifier = Self.defaultBundleIdentifier
            windowKeys = HerdrWindowKeys()
            return
        }
        guard case let .object(settings) = herdr else {
            throw AppConfigurationError(path: "integrations.herdr", reason: "Expected an object.")
        }
        let known: Set = ["terminalBundleIdentifier", "windowKeys"]
        if let unknown = settings.keys.sorted().first(where: { !known.contains($0) }) {
            throw AppConfigurationError(path: "integrations.herdr.\(unknown)", reason: "Unknown setting.")
        }
        windowKeys = try settings["windowKeys"].map(HerdrWindowKeys.init) ?? HerdrWindowKeys()
        guard let target = settings["terminalBundleIdentifier"] else {
            bundleIdentifier = Self.defaultBundleIdentifier
            return
        }
        guard case let .string(identifier) = target, Self.isValidBundleIdentifier(identifier) else {
            throw AppConfigurationError(
                path: "integrations.herdr.terminalBundleIdentifier",
                reason: "Expected a bundle identifier such as com.apple.Terminal."
            )
        }
        bundleIdentifier = identifier
    }

    private static func isValidBundleIdentifier(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { scalar in
                (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
                    || (48...57).contains(scalar.value) || scalar.value == 45
            }
        }
    }
}

/// The key Dispatch presses for each step through Herdr's window. Each must
/// match the key bound to that step in Herdr's `config.toml`. Herdr leaves
/// these steps unbound by default; F16 to F19 have no macOS or common
/// terminal meaning, so they are the defaults.
struct HerdrWindowKeys: Equatable, Sendable {
    private static let steps: [(name: String, step: HerdrClientNavigation)] = [
        ("previousAgent", .previousAgent),
        ("previousWorkspace", .previousWorkspace),
        ("nextWorkspace", .nextWorkspace),
        ("nextAgent", .nextAgent)
    ]

    private var previousAgent = KeyboardShortcut(key: .f16)
    private var previousWorkspace = KeyboardShortcut(key: .f17)
    private var nextWorkspace = KeyboardShortcut(key: .f18)
    private var nextAgent = KeyboardShortcut(key: .f19)

    init() {}

    /// Reads `integrations.herdr.windowKeys`. A step left out keeps its default.
    init(_ value: JSONValue) throws {
        let path = "integrations.herdr.windowKeys"
        guard case let .object(entries) = value else {
            throw AppConfigurationError(path: path, reason: "Expected an object.")
        }
        if let unknown = entries.keys.sorted().first(where: { name in !Self.steps.contains { $0.name == name } }) {
            throw AppConfigurationError(
                path: "\(path).\(unknown)",
                reason: "Unknown step. Use previousAgent, previousWorkspace, nextWorkspace, or nextAgent."
            )
        }
        for (name, step) in Self.steps {
            guard let entry = entries[name] else { continue }
            self[step] = try Self.shortcut(entry, path: "\(path).\(name)")
        }
        for (index, first) in Self.steps.enumerated() {
            for second in Self.steps.dropFirst(index + 1) where self[first.step] == self[second.step] {
                throw AppConfigurationError(
                    path: "\(path).\(second.name)",
                    reason: "\(first.name) already uses this key. Give each step its own key."
                )
            }
        }
    }

    subscript(step: HerdrClientNavigation) -> KeyboardShortcut {
        get {
            switch step {
            case .previousAgent: previousAgent
            case .previousWorkspace: previousWorkspace
            case .nextWorkspace: nextWorkspace
            case .nextAgent: nextAgent
            }
        }
        set {
            switch step {
            case .previousAgent: previousAgent = newValue
            case .previousWorkspace: previousWorkspace = newValue
            case .nextWorkspace: nextWorkspace = newValue
            case .nextAgent: nextAgent = newValue
            }
        }
    }

    /// The same shape as `keyboard.shortcut`'s arguments.
    private static func shortcut(_ value: JSONValue, path: String) throws -> KeyboardShortcut {
        guard case let .object(fields) = value else {
            throw AppConfigurationError(path: path, reason: #"Expected an object such as { "key": "f16" }."#)
        }
        if let unknown = fields.keys.sorted().first(where: { $0 != "key" && $0 != "modifiers" }) {
            throw AppConfigurationError(path: "\(path).\(unknown)", reason: "Unknown field.")
        }
        guard case let .string(name)? = fields["key"], let key = KeyboardKey(rawValue: name) else {
            throw AppConfigurationError(path: "\(path).key", reason: "Expected a key name such as f16.")
        }
        guard let modifierValues = fields["modifiers"] else { return KeyboardShortcut(key: key) }
        guard case let .array(values) = modifierValues else {
            throw AppConfigurationError(path: "\(path).modifiers", reason: "Expected a list.")
        }
        let modifiers = try values.map { value in
            guard case let .string(name) = value, let modifier = ShortcutModifier(rawValue: name) else {
                throw AppConfigurationError(
                    path: "\(path).modifiers",
                    reason: "Expected command, option, control, shift, or function."
                )
            }
            return modifier
        }
        return KeyboardShortcut(key: key, modifiers: Set(modifiers))
    }
}

/// A problem in a setting the app interprets, worded like the core's
/// configuration diagnostics for the menu-bar panel.
struct AppConfigurationError: LocalizedError, CustomStringConvertible {
    let path: String
    let reason: String

    var description: String { "At \(path): \(reason)" }
    var errorDescription: String? { description }
}

/// Validates the app's own settings in the same load that the runtime
/// installs: Herdr's integration settings, and that every control the file
/// names exists on the pad.
struct ValidatingConfigurationLoader: ConfigurationLoading {
    let file: FileConfigurationLoader

    func load() async throws -> DispatchConfiguration {
        let configuration = try await file.load()
        _ = try HerdrTerminalConfiguration(configuration)
        try PadControlValidation.validate(configuration)
        return configuration
    }
}

/// The navigator asks for the installed snapshot at press time, including after reload.
actor HerdrTerminalConfigurationSource {
    private weak var runtime: DispatchRuntime?

    func attach(_ runtime: DispatchRuntime) {
        self.runtime = runtime
    }

    func settings() async -> HerdrTerminalConfiguration {
        guard let configuration = await runtime?.currentConfiguration(),
              let settings = try? HerdrTerminalConfiguration(configuration) else {
            return .defaults
        }
        return settings
    }
}
