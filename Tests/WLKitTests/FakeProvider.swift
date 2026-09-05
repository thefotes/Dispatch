@testable import WLKit

/// A `Provider` no test touches Herdr through — records every call so tests
/// can assert on dispatch, not on a live socket. Shared by `ProviderTests`
/// and `ProviderBridgeRoundTripTests`.
final class FakeProvider: Provider, @unchecked Sendable {
    var agentsToReturn: [HerdrAgent] = []
    var focusCalls: [String] = []
    var dialCalls: [(step: Int, mode: String)] = []
    var injectedTexts: [String] = []
    var injectError: Error?
    var joystickCalls: [String] = []
    var descriptionToReturn = ProviderDescription()
    private var onChangeCallback: (@Sendable () -> Void)?

    func describe() async -> ProviderDescription { descriptionToReturn }

    func status() async throws -> [HerdrAgent] { agentsToReturn }

    func focus(_ target: String) async throws { focusCalls.append(target) }

    func dial(_ step: Int, mode: String) async throws {
        dialCalls.append((step, mode))
    }

    func inject(_ text: String) async throws {
        if let injectError { throw injectError }
        injectedTexts.append(text)
    }

    func joystick(_ direction: String) async throws {
        joystickCalls.append(direction)
    }

    func subscribe(_ onChange: @escaping @Sendable () -> Void) -> ProviderSubscription {
        onChangeCallback = onChange
        return ProviderSubscription { [weak self] in self?.onChangeCallback = nil }
    }

    /// Drives whatever `subscribe` was last given — the test-only stand-in
    /// for a real provider noticing something changed.
    func fireChange() {
        onChangeCallback?()
    }
}
