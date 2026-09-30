import DispatchCore
import Foundation

public actor DispatchRuntime {
    nonisolated public let snapshots: AsyncStream<RuntimeSnapshot>

    private let pad: any PadDevice
    private let registry: ActionRegistry
    private let configurationLoader: any ConfigurationLoading
    private let reconnectPolicy: ReconnectPolicy
    private let heartbeatInterval: Duration
    private let snapshotContinuation: AsyncStream<RuntimeSnapshot>.Continuation

    private var resolver: BindingResolver?
    private var configuration: DispatchConfiguration?
    private var lifecycle = Lifecycle.idle
    private var snapshot = RuntimeSnapshot.disabled
    /// The lighting most recently asked for, kept so the heartbeat can write
    /// it again after a failed write.
    private var requestedPresentation: PadPresentation?

    /// What the runtime is doing with the pad. Each case holds the tasks that
    /// belong to it, so a task can only exist in the state that owns it and
    /// stop() can always reach it. specs/RuntimeLifecycle.tla models these
    /// transitions; keep the two in step.
    private enum Lifecycle {
        case idle
        /// start() could not install a configuration. The runtime stays on:
        /// a reload that installs one continues starting.
        case awaitingConfiguration
        /// start() is loading the configuration or connecting.
        case starting(Task<Void, Never>)
        case running(events: Task<Void, Never>, heartbeat: Task<Void, Never>)
        case reconnecting(Task<Void, Never>)
        case stopping

        var tasks: [Task<Void, Never>] {
            switch self {
            case .idle, .awaitingConfiguration, .stopping: []
            case let .starting(task), let .reconnecting(task): [task]
            case let .running(events, heartbeat): [events, heartbeat]
            }
        }

        var isRunning: Bool {
            if case .running = self { true } else { false }
        }
    }

    public init(
        pad: any PadDevice,
        registrations: [ActionRegistration],
        configurationLoader: any ConfigurationLoading = FileConfigurationLoader(),
        reconnectPolicy: ReconnectPolicy = ReconnectPolicy(),
        heartbeatInterval: Duration = .seconds(15)
    ) throws {
        precondition(heartbeatInterval > .zero)
        self.pad = pad
        registry = try ActionRegistry(registrations: registrations)
        self.configurationLoader = configurationLoader
        self.reconnectPolicy = reconnectPolicy
        self.heartbeatInterval = heartbeatInterval
        (snapshots, snapshotContinuation) = AsyncStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        snapshotContinuation.yield(.disabled)
    }

    deinit {
        for task in lifecycle.tasks {
            task.cancel()
        }
        snapshotContinuation.finish()
    }

    public func currentSnapshot() -> RuntimeSnapshot {
        snapshot
    }

    public func currentConfiguration() -> DispatchConfiguration? {
        configuration
    }

    /// Loads the configuration and connects. Does nothing unless the runtime
    /// is idle, so overlapping calls start it once; a call made while it is
    /// stopping is ignored.
    public func start() async {
        guard case .idle = lifecycle else { return }
        publish(phase: .starting, issue: nil)
        let attempt = Task { [weak self] in
            guard let self else { return }
            await loadAndConnect()
        }
        lifecycle = .starting(attempt)
        await attempt.value
    }

    /// The body of start(). stop() cancels it, so every step after an await
    /// checks for cancellation before it changes the lifecycle.
    private func loadAndConnect() async {
        do {
            try await installConfiguration()
        } catch {
            guard !Task.isCancelled else { return }
            Log.logger.error("Could not install the configuration: \(String(describing: error), privacy: .public).")
            lifecycle = .awaitingConfiguration
            publish(phase: .degraded, issue: .configuration(ConfigurationDiagnostic.message(for: error)))
            return
        }
        guard !Task.isCancelled else { return }

        publish(phase: .connecting, issue: nil)
        await connectPad()
    }

    /// The rest of starting once a configuration is installed. It runs on a
    /// start attempt's task, which stop() cancels.
    private func connectPad() async {
        guard !Task.isCancelled else { return }
        do {
            try await pad.connect()
        } catch {
            guard !Task.isCancelled else { return }
            Log.logger.error("Could not connect to the pad: \(String(describing: error), privacy: .private).")
            publish(phase: .degraded, issue: .device(String(describing: error)))
            scheduleReconnect(disconnectingFirst: false)
            return
        }
        guard !Task.isCancelled else {
            await pad.disconnect()
            return
        }

        beginConsumingEvents()
        Log.logger.info("Connected to the pad.")
    }

    private func beginConsumingEvents() {
        publish(phase: .operational, issue: nil)
        // A fresh subscription per connection: this task is cancelled on
        // device loss and stop, which permanently ends the stream it iterates.
        let events = pad.events()
        let eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
            guard !Task.isCancelled else { return }
            await self?.handleDeviceLoss(EventStreamEnded())
        }
        let heartbeatTask = Task { [weak self] in
            guard let self else { return }
            await monitorDeviceHealth()
        }
        lifecycle = .running(events: eventTask, heartbeat: heartbeatTask)
    }

    /// Cancels whatever the runtime is doing, clears the pad's lighting, and
    /// disconnects. It waits for an in-flight start or reconnect to finish
    /// first, so neither can connect the pad after stop() returns.
    public func stop() async {
        switch lifecycle {
        case .stopping:
            return
        case .idle:
            guard snapshot.phase != .disabled else { return }
        case .awaitingConfiguration, .starting, .running, .reconnecting:
            break
        }
        Log.logger.info("Stopping Dispatch.")
        let previous = lifecycle
        lifecycle = .stopping
        publish(phase: .stopping, issue: nil)
        for task in previous.tasks {
            task.cancel()
        }
        switch previous {
        case let .starting(task), let .reconnecting(task):
            await task.value
        case .idle, .awaitingConfiguration, .running, .stopping:
            // Event handling and health checks do not touch the connection,
            // and check the lifecycle before reporting, so stop() need not
            // wait for an in-progress action.
            break
        }
        do {
            try await pad.apply(PadPresentation())
        } catch {
            publish(phase: .degraded, issue: .presentation(String(describing: error)))
        }
        await pad.disconnect()
        resolver = nil
        configuration = nil
        requestedPresentation = nil
        lifecycle = .idle
        publish(phase: .disabled, issue: nil)
    }

    /// Installs the configuration again. If start() was waiting for a valid
    /// configuration, it then finishes starting, like start() it returns once
    /// the pad is connected or a reconnect is scheduled.
    public func reloadConfiguration() async {
        Log.logger.info("Reloading the configuration.")
        do {
            try await installConfiguration()
        } catch {
            Log.logger.error("Could not reload the configuration: \(String(describing: error), privacy: .public).")
            publish(phase: .degraded, issue: .configuration(ConfigurationDiagnostic.message(for: error)))
            return
        }
        guard case .awaitingConfiguration = lifecycle else {
            if case .configuration? = snapshot.issue {
                publish(phase: settledPhase, issue: nil)
            }
            return
        }
        publish(phase: .connecting, issue: nil)
        let attempt = Task { [weak self] in
            guard let self else { return }
            await connectPad()
        }
        lifecycle = .starting(attempt)
        await attempt.value
    }

    /// Writes the pad's lighting while it is running. Otherwise the pad is
    /// not connected, and AppModel applies the presentation again once the
    /// runtime reports operational. After a failed write the heartbeat writes
    /// the latest presentation again, because AppModel only applies again
    /// once Herdr's state changes, which may not happen for a long time.
    public func apply(_ presentation: PadPresentation) async {
        requestedPresentation = presentation
        await write(presentation)
    }

    private func write(_ presentation: PadPresentation) async {
        guard lifecycle.isRunning else { return }
        do {
            try await pad.apply(presentation)
            if lifecycle.isRunning, case .presentation? = snapshot.issue {
                publish(phase: .operational, issue: nil)
            }
        } catch {
            guard lifecycle.isRunning else { return }
            publish(phase: .degraded, issue: .presentation(String(describing: error)))
        }
    }

    /// The phase to report once nothing is wrong.
    private var settledPhase: RuntimePhase {
        switch lifecycle {
        case .idle: .disabled
        case .running: .operational
        case .reconnecting: .connecting
        case .awaitingConfiguration, .starting, .stopping: snapshot.phase
        }
    }

    private func installConfiguration() async throws {
        let configuration = try await configurationLoader.load()
        let compiled = try CompiledBindings.compile(configuration, catalog: registry.catalog)
        resolver = BindingResolver(bindings: compiled)
        self.configuration = configuration
        Log.logger.info("Installed configuration version \(configuration.version, privacy: .public).")
        publish(
            phase: snapshot.phase,
            issue: snapshot.issue,
            configurationVersion: configuration.version
        )
    }

    /// Logs at notice level so presses survive in the persisted log. The
    /// queue delay separates when a control was pressed from when its actions
    /// ran, since events are handled one at a time.
    private func handle(_ event: DispatchEvent) async {
        guard let resolver else { return }
        let actions = resolver.resolve(event)
        let queueDelay = Int(Date().timeIntervalSince(event.timestamp) * 1000)
        Log.logger.notice("""
            Pad \(event.control.description, privacy: .public) \(event.gesture.description, privacy: .public) \
            at \(event.timestamp.timeIntervalSince1970, format: .fixed(precision: 3), privacy: .public), \
            handled after \(queueDelay, privacy: .public) ms, \(actions.count, privacy: .public) action(s).
            """)
        var failure: RuntimeIssue?
        for action in actions {
            let clock = ContinuousClock()
            let started = clock.now
            do {
                try await registry.execute(action)
                Log.logger.notice("""
                    Ran \(action.id.rawValue, privacy: .public) in \
                    \(Self.milliseconds(clock.now - started), privacy: .public) ms.
                    """)
            } catch {
                Log.logger.error("""
                    \(action.id.rawValue, privacy: .public) failed after \
                    \(Self.milliseconds(clock.now - started), privacy: .public) ms.
                    """)
                failure = .action(action.id, String(describing: error))
                break
            }
        }
        recordHandledEvent(executedAction: !actions.isEmpty, failure: failure)
    }

    private func recordHandledEvent(executedAction: Bool, failure: RuntimeIssue?) {
        let processedEventCount = snapshot.processedEventCount &+ 1
        guard lifecycle.isRunning else {
            // The connection that delivered this event has since ended, so its
            // outcome no longer describes the runtime.
            publish(phase: snapshot.phase, issue: snapshot.issue, processedEventCount: processedEventCount)
            return
        }
        if let failure {
            publish(phase: .degraded, issue: failure, processedEventCount: processedEventCount)
        } else if executedAction, case .action? = snapshot.issue {
            publish(phase: .operational, issue: nil, processedEventCount: processedEventCount)
        } else {
            publish(
                phase: snapshot.phase == .degraded ? .degraded : .operational,
                issue: snapshot.issue,
                processedEventCount: processedEventCount
            )
        }
    }

    private func scheduleReconnect(disconnectingFirst: Bool) {
        let pad = pad
        let policy = reconnectPolicy
        lifecycle = .reconnecting(Task { [weak self] in
            if disconnectingFirst {
                await pad.disconnect()
            }
            var delay = policy.initialDelay
            while !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                do {
                    try await pad.connect()
                } catch {
                    await self?.recordReconnectFailure(error)
                    delay = policy.nextDelay(after: delay)
                    continue
                }
                if await self?.resumeAfterReconnect() != true {
                    await pad.disconnect()
                }
                return
            }
        })
    }

    /// Runs on the reconnect task, so cancellation here means stop() began
    /// while the connect was in flight.
    private func resumeAfterReconnect() -> Bool {
        guard !Task.isCancelled else { return false }
        beginConsumingEvents()
        Log.logger.info("Reconnected to the pad.")
        return true
    }

    private func monitorDeviceHealth() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: heartbeatInterval)
                guard !Task.isCancelled else { return }
                try await pad.checkHealth()
                await retryFailedPresentation()
            } catch is CancellationError {
                return
            } catch {
                handleDeviceLoss(error)
                return
            }
        }
    }

    /// Runs on the heartbeat task, so cancellation here means the connection
    /// it checked has ended.
    private func retryFailedPresentation() async {
        guard !Task.isCancelled, case .presentation? = snapshot.issue,
              let requestedPresentation else { return }
        Log.logger.info("Writing the pad's lighting again after a failed write.")
        await write(requestedPresentation)
    }

    /// Runs on a heartbeat or event task. A cancelled task belongs to a
    /// connection stop() has already ended, so its failure is not a loss.
    private func handleDeviceLoss(_ error: any Error) {
        guard !Task.isCancelled, case let .running(events, heartbeat) = lifecycle else { return }
        Log.logger.error("Lost the pad: \(String(describing: error), privacy: .private).")
        events.cancel()
        heartbeat.cancel()
        publish(phase: .degraded, issue: .device(String(describing: error)))
        scheduleReconnect(disconnectingFirst: true)
    }

    /// Runs on the reconnect task; once stop() has cancelled it, the failure
    /// is no longer news.
    private func recordReconnectFailure(_ error: any Error) {
        guard !Task.isCancelled else { return }
        Log.logger.error("Reconnecting to the pad failed: \(String(describing: error), privacy: .private).")
        publish(phase: .degraded, issue: .device(String(describing: error)))
    }

    private func publish(
        phase: RuntimePhase,
        issue: RuntimeIssue?,
        processedEventCount: UInt64? = nil,
        configurationVersion: Int? = nil
    ) {
        snapshot = RuntimeSnapshot(
            phase: phase,
            issue: issue,
            processedEventCount: processedEventCount ?? snapshot.processedEventCount,
            configurationVersion: configurationVersion ?? snapshot.configurationVersion
        )
        snapshotContinuation.yield(snapshot)
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

private struct EventStreamEnded: Error, CustomStringConvertible {
    var description: String { "The pad event stream ended." }
}

public struct ReconnectPolicy: Sendable {
    public let initialDelay: Duration
    public let maximumDelay: Duration
    public let multiplier: Double

    public init(
        initialDelay: Duration = .seconds(1),
        maximumDelay: Duration = .seconds(30),
        multiplier: Double = 2
    ) {
        precondition(multiplier >= 1)
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.multiplier = multiplier
    }

    func nextDelay(after delay: Duration) -> Duration {
        let seconds = Double(delay.components.seconds)
            + Double(delay.components.attoseconds) / 1_000_000_000_000_000_000
        let maximumSeconds = Double(maximumDelay.components.seconds)
            + Double(maximumDelay.components.attoseconds) / 1_000_000_000_000_000_000
        return .seconds(Swift.min(seconds * multiplier, maximumSeconds))
    }
}
