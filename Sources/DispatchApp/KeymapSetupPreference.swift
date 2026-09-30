import DispatchCreatorMicro
import Foundation

/// Consent belongs to the app, not to the device-independent configuration.
@MainActor
struct KeymapSetupPreference {
    private static let key = "keymapSetupAllowed"
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var allowed: Bool { defaults.bool(forKey: Self.key) }

    func setAllowed(_ allowed: Bool) {
        defaults.set(allowed, forKey: Self.key)
    }

    /// Consent covers writing the keymap, so it is asked for only when a
    /// write is needed. A pad whose first layer already emits Dispatch's
    /// codes, such as one set up by Codex's Creator Micro support, is ready
    /// without it.
    func statusAfterConnecting(
        inspect: @MainActor () async throws -> CreatorMicroKeymapState
    ) async throws -> AppModel.KeymapStatus {
        switch try await inspect() {
        case .ready: .ready
        case .changed: allowed ? .changed : .consentNeeded
        }
    }
}
