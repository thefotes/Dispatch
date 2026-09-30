import DispatchMacOS
import DispatchProviders

/// Moves Herdr's window by bringing its terminal forward and pressing the key
/// that Herdr's `config.toml` binds to each step. Herdr 0.9.1 has no API for
/// its window, and only the window spans every connected machine.
///
/// The terminal and the keys come from `integrations.herdr` at press time;
/// see `HerdrWindowKeys` for the defaults.
struct KeyboardHerdrClientNavigator: HerdrClientNavigating {
    let automation: any MacOSAutomating
    let settings: @Sendable () async -> HerdrTerminalConfiguration

    func navigate(_ step: HerdrClientNavigation) async throws {
        let settings = await settings()
        try await automation.perform(.macro([
            .activate(ApplicationTarget(bundleIdentifier: settings.bundleIdentifier)),
            .shortcut(settings.windowKeys[step])
        ]))
    }
}
