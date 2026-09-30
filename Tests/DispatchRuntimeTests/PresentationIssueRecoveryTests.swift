import DispatchCore
import DispatchRuntime
import DispatchTestSupport
import XCTest

final class PresentationIssueRecoveryTests: XCTestCase {
    func testSuccessfulApplyRecoversTransientPresentationIssue() async throws {
        let pad = FakePadDevice()
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: []))
        )
        await runtime.start()

        pad.setPresentationError(.presentationFailed)
        await runtime.apply(Self.presentation())
        var snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .degraded)
        guard case .presentation? = snapshot.issue else {
            return XCTFail("Expected presentation issue")
        }

        pad.setPresentationError(nil)
        await runtime.apply(Self.presentation())
        snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .operational)
        XCTAssertNil(snapshot.issue)
        await runtime.stop()
    }

    /// Nothing applies again after the failure: the app stops sending
    /// lighting while the runtime is degraded, so the runtime must retry.
    func testHeartbeatRetriesFailedLightingOnceThePadAnswers() async throws {
        let pad = FakePadDevice()
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: [])),
            heartbeatInterval: .milliseconds(10)
        )
        await runtime.start()
        pad.setPresentationError(.presentationFailed)
        await runtime.apply(Self.presentation())
        let failedSnapshot = await runtime.currentSnapshot()
        guard case .presentation? = failedSnapshot.issue else {
            return XCTFail("Expected presentation issue")
        }

        pad.setPresentationError(nil)

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await runtime.currentSnapshot().phase != .operational, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .operational)
        XCTAssertNil(snapshot.issue)
        XCTAssertEqual(pad.recordedPresentations(), [Self.presentation()])
        await runtime.stop()
    }

    func testSuccessfulApplyDoesNotClearConfigurationIssue() async throws {
        let loader = MutableConfigurationLoader(DispatchConfiguration(bindings: []))
        let pad = FakePadDevice()
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [],
            configurationLoader: loader
        )
        await runtime.start()

        await loader.set(DispatchConfiguration(bindings: [
            BindingDefinition(
                event: EventPattern(control: .key(1), gesture: .pressed),
                actions: [ConfiguredAction(id: "missing.action")]
            )
        ]))
        await runtime.reloadConfiguration()
        var snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .degraded)
        guard case .configuration? = snapshot.issue else {
            return XCTFail("Expected configuration issue")
        }

        await runtime.apply(Self.presentation())
        snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .degraded)
        guard case .configuration? = snapshot.issue else {
            return XCTFail("Expected configuration issue to persist")
        }
        await runtime.stop()
    }

    func testSuccessfulReloadClearsConfigurationIssue() async throws {
        let loader = MutableConfigurationLoader(DispatchConfiguration(bindings: []))
        let runtime = try DispatchRuntime(
            pad: FakePadDevice(),
            registrations: [],
            configurationLoader: loader
        )
        await runtime.start()
        await loader.set(DispatchConfiguration(bindings: [
            BindingDefinition(
                event: EventPattern(control: .key(1), gesture: .pressed),
                actions: [ConfiguredAction(id: "missing.action")]
            )
        ]))
        await runtime.reloadConfiguration()
        let failedSnapshot = await runtime.currentSnapshot()
        XCTAssertEqual(failedSnapshot.phase, .degraded)
        guard case .configuration? = failedSnapshot.issue else {
            return XCTFail("Expected configuration issue")
        }

        await loader.set(DispatchConfiguration(bindings: []))
        await runtime.reloadConfiguration()

        let recoveredSnapshot = await runtime.currentSnapshot()
        XCTAssertEqual(recoveredSnapshot.phase, .operational)
        XCTAssertNil(recoveredSnapshot.issue)
        await runtime.stop()
    }

    func testSuccessfulReloadKeepsUnresolvedPresentationIssue() async throws {
        let pad = FakePadDevice()
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: []))
        )
        await runtime.start()
        pad.setPresentationError(.presentationFailed)
        await runtime.apply(Self.presentation())
        let failedSnapshot = await runtime.currentSnapshot()
        XCTAssertEqual(failedSnapshot.phase, .degraded)
        guard case .presentation? = failedSnapshot.issue else {
            return XCTFail("Expected presentation issue")
        }

        await runtime.reloadConfiguration()

        let reloadedSnapshot = await runtime.currentSnapshot()
        XCTAssertEqual(reloadedSnapshot.phase, .degraded)
        XCTAssertEqual(reloadedSnapshot.issue, failedSnapshot.issue)
        await runtime.stop()
    }

    private static func presentation() -> PadPresentation {
        PadPresentation(controls: [:], ambient: nil)
    }
}

private actor MutableConfigurationLoader: ConfigurationLoading {
    private var configuration: DispatchConfiguration

    init(_ configuration: DispatchConfiguration) {
        self.configuration = configuration
    }

    func set(_ configuration: DispatchConfiguration) {
        self.configuration = configuration
    }

    func load() -> DispatchConfiguration {
        configuration
    }
}
