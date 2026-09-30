import DispatchCore
import DispatchRuntime
import DispatchTestSupport
import Foundation
import XCTest

final class DispatchRuntimeTests: XCTestCase {
    func testEventResolvesAndExecutesWithoutControllingComputer() async throws {
        let actionID: ActionID = "test.record"
        let definition = ActionDefinition(
            id: actionID,
            title: "Record",
            summary: "Records an invocation"
        )
        let sink = RecordingActionSink()
        let pad = FakePadDevice()
        let configuration = DispatchConfiguration(bindings: [
            BindingDefinition(
                event: EventPattern(control: .key(9), gesture: .pressed),
                actions: [ConfiguredAction(id: actionID)]
            )
        ])
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [sink.registration(definition: definition)],
            configurationLoader: StaticConfigurationLoader(configuration)
        )

        await runtime.start()
        pad.emit(Self.event(control: .key(9), gesture: .pressed))

        try await waitUntil {
            let count = await runtime.currentSnapshot().processedEventCount
            let invocations = await sink.recordedInvocations()
            return count == 1 && invocations.count == 1
        }
        let invocations = await sink.recordedInvocations()
        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(invocations.map(\.id), [actionID])
        XCTAssertEqual(snapshot.processedEventCount, 1)
        XCTAssertTrue(pad.isConnected())
    }

    func testUnboundEventDoesNothingButIsProcessed() async throws {
        let sink = RecordingActionSink()
        let pad = FakePadDevice()
        let definition = ActionDefinition(
            id: "test.record",
            title: "Record",
            summary: "Records an invocation"
        )
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [sink.registration(definition: definition)],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: []))
        )

        await runtime.start()
        pad.emit(Self.event(control: .key(3), gesture: .pressed))

        try await waitUntil {
            await runtime.currentSnapshot().processedEventCount == 1
        }
        let invocations = await sink.recordedInvocations()
        XCTAssertEqual(invocations, [])
    }

    func testInvalidInitialConfigurationDoesNotConnectPad() async throws {
        let pad = FakePadDevice()
        let configuration = DispatchConfiguration(bindings: [
            BindingDefinition(
                event: EventPattern(control: .key(1), gesture: .pressed),
                actions: [ConfiguredAction(id: "missing.action")]
            )
        ])
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [],
            configurationLoader: StaticConfigurationLoader(configuration)
        )

        await runtime.start()

        XCTAssertFalse(pad.isConnected())
        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .degraded)
        guard case .configuration? = snapshot.issue else {
            return XCTFail("Expected a configuration issue")
        }
    }

    func testValidReloadAfterInvalidInitialConfigurationConnectsPad() async throws {
        let pad = FakePadDevice()
        let loader = MutableConfigurationLoader(Self.invalidConfiguration)
        let runtime = try DispatchRuntime(pad: pad, registrations: [], configurationLoader: loader)
        await runtime.start()
        XCTAssertFalse(pad.isConnected())

        await loader.set(DispatchConfiguration(bindings: []))
        await runtime.reloadConfiguration()

        XCTAssertTrue(pad.isConnected())
        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .operational)
        XCTAssertNil(snapshot.issue)
        await runtime.stop()
    }

    func testInvalidReloadWhileAwaitingConfigurationStaysDegraded() async throws {
        let pad = FakePadDevice()
        let loader = MutableConfigurationLoader(Self.invalidConfiguration)
        let runtime = try DispatchRuntime(pad: pad, registrations: [], configurationLoader: loader)
        await runtime.start()

        await runtime.reloadConfiguration()

        XCTAssertFalse(pad.isConnected())
        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .degraded)
        guard case .configuration? = snapshot.issue else {
            return XCTFail("Expected a configuration issue")
        }
    }

    func testStopWhileAwaitingConfigurationStaysOffAfterValidReload() async throws {
        let pad = FakePadDevice()
        let loader = MutableConfigurationLoader(Self.invalidConfiguration)
        let runtime = try DispatchRuntime(pad: pad, registrations: [], configurationLoader: loader)
        await runtime.start()

        await runtime.stop()
        await loader.set(DispatchConfiguration(bindings: []))
        await runtime.reloadConfiguration()

        XCTAssertFalse(pad.isConnected())
        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .disabled)
    }

    private static let invalidConfiguration = DispatchConfiguration(bindings: [
        BindingDefinition(
            event: EventPattern(control: .key(1), gesture: .pressed),
            actions: [ConfiguredAction(id: "missing.action")]
        )
    ])

    func testInvalidConfigurationFileIsReportedWithItsLocation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try Data(#"{"version": 1, "bindings": [], "x": 1}"#.utf8).write(to: url)
        let runtime = try DispatchRuntime(
            pad: FakePadDevice(),
            registrations: [],
            configurationLoader: FileConfigurationLoader(url: url, writeFallbackWhenMissing: false)
        )

        await runtime.start()

        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.issue, .configuration(#"At the top level: Unknown field "x"."#))
    }

    func testInvalidReloadKeepsPreviousBindingsActive() async throws {
        let actionID: ActionID = "test.record"
        let sink = RecordingActionSink()
        let pad = FakePadDevice()
        let loader = MutableConfigurationLoader(
            DispatchConfiguration(bindings: [
                BindingDefinition(
                    event: EventPattern(control: .key(2), gesture: .pressed),
                    actions: [ConfiguredAction(id: actionID)]
                )
            ])
        )
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [
                sink.registration(
                    definition: ActionDefinition(
                        id: actionID,
                        title: "Record",
                        summary: "Records an invocation"
                    )
                )
            ],
            configurationLoader: loader
        )
        await runtime.start()
        await loader.set(
            DispatchConfiguration(bindings: [
                BindingDefinition(
                    event: EventPattern(control: .key(2), gesture: .pressed),
                    actions: [ConfiguredAction(id: "missing.action")]
                )
            ])
        )

        await runtime.reloadConfiguration()
        pad.emit(Self.event(control: .key(2), gesture: .pressed))

        try await waitUntil {
            await sink.recordedInvocations().count == 1
        }
        let invocations = await sink.recordedInvocations()
        XCTAssertEqual(invocations.map(\.id), [actionID])
    }

    func testStopClearsPresentationAndDisconnects() async throws {
        let pad = FakePadDevice()
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: []))
        )
        await runtime.start()

        await runtime.stop()

        let snapshot = await runtime.currentSnapshot()
        XCTAssertFalse(pad.isConnected())
        XCTAssertEqual(pad.recordedPresentations().last, PadPresentation())
        XCTAssertEqual(snapshot.phase, .disabled)
    }

    func testConnectionFailureRetriesWithoutRebuildingRuntime() async throws {
        let pad = FakePadDevice()
        pad.setConnectionError(.connectionFailed)
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: [])),
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10),
                maximumDelay: .milliseconds(20)
            )
        )

        await runtime.start()
        pad.setConnectionError(nil)

        try await waitUntil {
            await runtime.currentSnapshot().phase == .operational && pad.isConnected()
        }
        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .operational)
        await runtime.stop()
    }

    func testReconnectDelayGrowsAndStopsAtMaximum() async throws {
        let pad = TimedFailingPad()
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: [])),
            reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(50), maximumDelay: .milliseconds(200))
        )
        await runtime.start()
        try await waitUntil(timeout: .seconds(2)) { pad.attempts().count >= 5 }
        await runtime.stop()

        let attempts = pad.attempts()
        XCTAssertGreaterThanOrEqual(attempts.count, 5)
        guard attempts.count >= 5 else { return }
        let delays = zip(attempts, attempts.dropFirst()).prefix(4).map { $1 - $0 }
        XCTAssertGreaterThanOrEqual(delays[0], .milliseconds(40))
        XCTAssertGreaterThanOrEqual(delays[1], .milliseconds(90))
        XCTAssertGreaterThanOrEqual(delays[2], .milliseconds(180))
        XCTAssertGreaterThanOrEqual(delays[3], .milliseconds(180))
        XCTAssertLessThan(delays[3], .milliseconds(350))
    }

    func testReloadDuringReconnectDoesNotPreventStop() async throws {
        let pad = FakePadDevice()
        pad.setConnectionError(.connectionFailed)
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: [])),
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(50),
                maximumDelay: .milliseconds(50)
            )
        )

        await runtime.start()
        await runtime.reloadConfiguration()
        var snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .degraded)
        guard case .device? = snapshot.issue else {
            return XCTFail("Expected reconnecting device issue to persist")
        }
        await runtime.stop()
        pad.setConnectionError(nil)
        try await Task.sleep(for: .milliseconds(100))

        snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .disabled)
        XCTAssertFalse(pad.isConnected())
    }

    func testSuccessfulActionRecoversTransientActionIssue() async throws {
        let actionID: ActionID = "test.flaky"
        let action = FailOnceAction()
        let pad = FakePadDevice()
        let configuration = DispatchConfiguration(bindings: [
            BindingDefinition(
                event: EventPattern(control: .key(1), gesture: .pressed),
                actions: [ConfiguredAction(id: actionID)]
            )
        ])
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [action.registration(id: actionID)],
            configurationLoader: StaticConfigurationLoader(configuration)
        )
        await runtime.start()

        pad.emit(Self.event(control: .key(1), gesture: .pressed))
        try await waitUntil { await runtime.currentSnapshot().processedEventCount == 1 }
        var snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .degraded)
        guard case .action? = snapshot.issue else { return XCTFail("Expected action issue") }

        pad.emit(Self.event(control: .key(1), gesture: .pressed))
        try await waitUntil { await runtime.currentSnapshot().processedEventCount == 2 }
        snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .operational)
        XCTAssertNil(snapshot.issue)
        await runtime.stop()
    }

    func testMacroStopsAtFirstFailingAction() async throws {
        let pad = FakePadDevice()
        let sink = RecordingActionSink()
        let first: ActionID = "test.first"
        let failing: ActionID = "test.failing"
        let last: ActionID = "test.last"
        let failure = FailOnceAction()
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [
                sink.registration(definition: ActionDefinition(id: first, title: "First", summary: "First step")),
                failure.registration(id: failing),
                sink.registration(definition: ActionDefinition(id: last, title: "Last", summary: "Last step"))
            ],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: [
                BindingDefinition(
                    event: EventPattern(control: .key(1), gesture: .pressed),
                    actions: [ConfiguredAction(id: first), ConfiguredAction(id: failing), ConfiguredAction(id: last)]
                )
            ]))
        )
        await runtime.start()

        pad.emit(Self.event(control: .key(1), gesture: .pressed))
        try await waitUntil { await runtime.currentSnapshot().processedEventCount == 1 }

        let invocations = await sink.recordedInvocations()
        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(invocations.map(\.id), [first])
        guard case let .action(actionID, _)? = snapshot.issue else {
            return XCTFail("Expected action failure")
        }
        XCTAssertEqual(actionID, failing)
        await runtime.stop()
    }

    func testHeartbeatDetectsDeviceLossAndReconnects() async throws {
        let pad = FakePadDevice()
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: [])),
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10),
                maximumDelay: .milliseconds(20)
            ),
            heartbeatInterval: .milliseconds(10)
        )
        await runtime.start()
        // Keep the loss observable until the test releases reconnection.
        pad.setConnectionError(.connectionFailed)
        pad.setHealthCheckError(.healthCheckFailed)

        try await waitUntil {
            await runtime.currentSnapshot().phase == .degraded && !pad.isConnected()
        }
        pad.setHealthCheckError(nil)
        pad.setConnectionError(nil)

        try await waitUntil {
            await runtime.currentSnapshot().phase == .operational
                && pad.recordedConnectionCount() >= 2
                && pad.recordedHealthCheckCount() >= 1
        }
        await runtime.stop()
    }

    func testEventStreamCompletionReportsDeviceLoss() async throws {
        let pad = FakePadDevice()
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: [])),
            reconnectPolicy: ReconnectPolicy(initialDelay: .seconds(1), maximumDelay: .seconds(1)),
            heartbeatInterval: .seconds(10)
        )
        await runtime.start()
        let initialSnapshot = await runtime.currentSnapshot()
        XCTAssertEqual(initialSnapshot.phase, .operational)

        pad.endEvents()
        try await waitUntil { await runtime.currentSnapshot().phase == .degraded }
        let snapshot = await runtime.currentSnapshot()
        guard case .device? = snapshot.issue else {
            return XCTFail("Expected a device issue after event stream completion")
        }
        await runtime.stop()
    }

    func testEventsStillExecuteActionsAfterHeartbeatReconnect() async throws {
        let (runtime, pad, sink) = try Self.recordingRuntime(heartbeatInterval: .milliseconds(10))
        await runtime.start()
        pad.setConnectionError(.connectionFailed)
        pad.setHealthCheckError(.healthCheckFailed)
        try await waitUntil {
            await runtime.currentSnapshot().phase == .degraded && !pad.isConnected()
        }
        pad.setHealthCheckError(nil)
        pad.setConnectionError(nil)
        try await waitUntil {
            await runtime.currentSnapshot().phase == .operational && pad.recordedConnectionCount() >= 2
        }

        pad.emit(Self.event(control: .key(0), gesture: .pressed))

        try await waitUntil { await sink.recordedInvocations().count == 1 }
        await runtime.stop()
    }

    func testEventsStillExecuteActionsAfterStopAndStart() async throws {
        let (runtime, pad, sink) = try Self.recordingRuntime()
        await runtime.start()
        await runtime.stop()
        await runtime.start()

        pad.emit(Self.event(control: .key(0), gesture: .pressed))

        try await waitUntil { await sink.recordedInvocations().count == 1 }
        await runtime.stop()
    }

    private static func recordingRuntime(
        heartbeatInterval: Duration = .seconds(15)
    ) throws -> (DispatchRuntime, FakePadDevice, RecordingActionSink) {
        let actionID: ActionID = "test.record"
        let sink = RecordingActionSink()
        let pad = FakePadDevice()
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [sink.registration(
                definition: ActionDefinition(id: actionID, title: "Record", summary: "Records an invocation")
            )],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: [
                BindingDefinition(
                    event: EventPattern(control: .key(0), gesture: .pressed),
                    actions: [ConfiguredAction(id: actionID)]
                )
            ])),
            reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(10), maximumDelay: .milliseconds(20)),
            heartbeatInterval: heartbeatInterval
        )
        return (runtime, pad, sink)
    }

    func testStopDuringPendingReconnectDoesNotResumeConsumption() async throws {
        let pad = GatedConnectPad()
        pad.setFailFirstConnect(true)
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: [])),
            reconnectPolicy: ReconnectPolicy(initialDelay: .milliseconds(5), maximumDelay: .milliseconds(10))
        )

        await runtime.start()
        try await pad.waitUntilConnectAttempt(2)
        // stop() waits for the in-flight connect, so release it meanwhile.
        let stopping = Task { await runtime.stop() }
        try await waitUntil { await runtime.currentSnapshot().phase == .stopping }
        pad.releaseConnect()
        await stopping.value

        try await Task.sleep(for: .milliseconds(50))
        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .disabled)
        XCTAssertEqual(snapshot.processedEventCount, 0)
        XCTAssertFalse(pad.isConnected())
    }

    func testStopWhileStartIsConnectingLeavesRuntimeStopped() async throws {
        let pad = GatedConnectPad()
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: []))
        )

        let starting = Task { await runtime.start() }
        try await pad.waitUntilConnectStarted()
        let stopping = Task { await runtime.stop() }
        try await waitUntil { await runtime.currentSnapshot().phase == .stopping }
        pad.releaseConnect()
        await stopping.value
        await starting.value

        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .disabled)
        XCTAssertFalse(pad.isConnected())
    }

    func testOverlappingStartsHandleEachEventOnce() async throws {
        let actionID: ActionID = "test.record"
        let sink = RecordingActionSink()
        let pad = GatedConnectPad()
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [sink.registration(
                definition: ActionDefinition(id: actionID, title: "Record", summary: "Records an invocation")
            )],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: [
                BindingDefinition(
                    event: EventPattern(control: .key(0), gesture: .pressed),
                    actions: [ConfiguredAction(id: actionID)]
                )
            ]))
        )

        let first = Task { await runtime.start() }
        try await pad.waitUntilConnectStarted()
        let second = Task { await runtime.start() }
        await second.value
        pad.releaseConnect()
        await first.value
        pad.emit(Self.event(control: .key(0), gesture: .pressed))

        try await waitUntil { await runtime.currentSnapshot().processedEventCount >= 1 }
        try await Task.sleep(for: .milliseconds(50))
        let invocations = await sink.recordedInvocations()
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(pad.recordedConnectAttempts(), 1)
        await runtime.stop()
    }

    func testApplyWhileStoppedReportsNoIssue() async throws {
        let pad = FakePadDevice()
        pad.setPresentationError(.presentationFailed)
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: []))
        )

        await runtime.apply(Self.presentation())

        let snapshot = await runtime.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .disabled)
        XCTAssertNil(snapshot.issue)
    }

    func testFileLoaderCreatesAReadableDefaultWithoutOverwritingEdits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-config-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fallback = DispatchConfiguration(bindings: [])
        let loader = FileConfigurationLoader(url: url, fallback: fallback)

        let installed = try await loader.load()
        XCTAssertEqual(installed, fallback)
        XCTAssertEqual(
            try JSONDecoder().decode(DispatchConfiguration.self, from: Data(contentsOf: url)),
            fallback
        )

        let edited = DispatchConfiguration(version: 7, bindings: [])
        try JSONEncoder().encode(edited).write(to: url, options: .atomic)
        let reloaded = try await loader.load()
        XCTAssertEqual(reloaded, edited)
    }

    private static func presentation() -> PadPresentation {
        PadPresentation(controls: [:], ambient: nil)
    }

    private static func event(control: LogicalControl, gesture: Gesture) -> DispatchEvent {
        DispatchEvent(
            source: DeviceIdentity(rawValue: "test-pad"),
            control: control,
            gesture: gesture,
            timestamp: Date(timeIntervalSince1970: 1)
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await condition()) {
            guard clock.now < deadline else {
                XCTFail("Condition was not met before timeout")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class FailOnceAction: @unchecked Sendable {
    private struct Failure: Error {}

    private let lock = NSLock()
    private var shouldFail = true

    func registration(id: ActionID) -> ActionRegistration {
        ActionRegistration(
            definition: ActionDefinition(id: id, title: "Flaky", summary: "Fails once")
        ) { [self] _ in
            let fails = lock.withLock {
                defer { shouldFail = false }
                return shouldFail
            }
            if fails { throw Failure() }
        }
    }
}

private final class GatedConnectPad: PadDevice, @unchecked Sendable {
    private let lock = NSLock()
    private let broadcast = EventBroadcast<DispatchEvent>()
    private var released = false
    private var connected = false
    private var continuation2: CheckedContinuation<Void, Never>?
    private var failFirstConnect = false
    private var connectAttempts = 0

    struct ConnectFailure: Error {}

    func events() -> AsyncStream<DispatchEvent> {
        broadcast.subscribe()
    }

    func setFailFirstConnect(_ value: Bool) {
        lock.withLock { failFirstConnect = value }
    }

    func connect() async throws {
        let decision: (shouldFail: Bool, shouldGate: Bool) = lock.withLock {
            connectAttempts += 1
            if failFirstConnect && connectAttempts == 1 { return (true, false) }
            if released {
                connected = true
                return (false, false)
            }
            return (false, true)
        }
        if decision.shouldFail { throw ConnectFailure() }
        guard decision.shouldGate else { return }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if released {
                    continuation.resume()
                } else {
                    continuation2 = continuation
                }
            }
        }
        lock.withLock { connected = true }
    }

    func disconnect() async {
        lock.withLock { connected = false }
    }

    func checkHealth() async throws {}

    func apply(_ presentation: PadPresentation) async throws {}

    func isConnected() -> Bool {
        lock.withLock { connected }
    }

    func waitUntilConnectStarted() async throws {
        try await waitUntilConnectAttempt(1)
    }

    func waitUntilConnectAttempt(_ attempt: Int) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while lock.withLock({ connectAttempts }) < attempt {
            guard clock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func emit(_ event: DispatchEvent) {
        broadcast.yield(event)
    }

    func recordedConnectAttempts() -> Int {
        lock.withLock { connectAttempts }
    }

    func releaseConnect() {
        lock.withLock {
            released = true
            continuation2?.resume()
            continuation2 = nil
        }
    }
}

private final class TimedFailingPad: PadDevice, @unchecked Sendable {
    private let lock = NSLock()
    private var timestamps: [ContinuousClock.Instant] = []

    func events() -> AsyncStream<DispatchEvent> { AsyncStream { _ in } }

    func connect() async throws {
        lock.withLock { timestamps.append(ContinuousClock().now) }
        throw FakePadError.connectionFailed
    }

    func disconnect() async {}
    func checkHealth() async throws {}
    func apply(_ presentation: PadPresentation) async throws {}

    func attempts() -> [ContinuousClock.Instant] {
        lock.withLock { timestamps }
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
