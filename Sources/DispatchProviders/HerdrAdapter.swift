import Foundation
import DispatchCore

public actor HerdrAdapter: HerdrControlling {
    private let client: any HerdrConnecting
    private let encoder: any HerdrWireActionEncoding
    private let navigator: (any HerdrClientNavigating)?
    private var state = HerdrState.disconnected
    private var observers: [UUID: AsyncStream<HerdrState>.Continuation] = [:]
    private var textCycle: TextCycle?
    private var hasStartedRefresh = false
    private var lastTransportFailure: String?
    private var slotPriority: [String]

    /// Without a `navigator`, actions that move Herdr's window are unavailable.
    /// `slotPriority` lists agent statuses in the order their agents take
    /// slots; see `setSlotPriority(_:)`.
    public init(
        client: any HerdrConnecting,
        encoder: any HerdrWireActionEncoding,
        navigator: (any HerdrClientNavigating)? = nil,
        slotPriority: [String] = []
    ) {
        self.client = client
        self.encoder = encoder
        self.navigator = navigator
        self.slotPriority = slotPriority
    }

    /// Agents take slots by status, most urgent first, so the few slots a pad
    /// has go to the agents that need the user. A status missing from
    /// `priority` ranks as `unknown`, or last if `unknown` is missing too.
    /// Agents with the same rank keep Herdr's order. The published state is
    /// already in slot order, so lights, lists, and slot presses agree.
    public func setSlotPriority(_ priority: [String]) {
        guard priority != slotPriority else { return }
        slotPriority = priority
        var reordered = state
        reordered.agents = reordered.agents.inSlotOrder(priority)
        publish(reordered)
    }

    /// Focus can move inside Herdr (a click, a keyboard shortcut) between
    /// polls, so an action relative to the focused pane, tab, or agent list
    /// resolves against a snapshot taken at press time, never the last poll.
    /// A successful action changes Herdr's focus, so the snapshot is also
    /// refreshed before returning to keep observers current.
    /// Typing text does not move focus, so the text cycle refreshes only once,
    /// before it resolves the focused pane.
    public func execute(_ action: HerdrAction) async throws {
        let concrete: HerdrAction
        switch HerdrSemanticResolver.plan(for: action) {
        case let .direct(action):
            concrete = action
        case let .fromCurrentState(resolve):
            try await refresh()
            concrete = try resolve(state)
            Log.logger.notice("""
                Resolved \(String(describing: action), privacy: .public) \
                to \(String(describing: concrete), privacy: .public).
                """)
        case let .cycleText(options):
            try await cycleText(options)
            return
        case let .client(step, count):
            try await navigate(step, count: count)
            return
        }
        _ = try await send(encoder.request(for: concrete))
        try? await refresh()
    }

    /// Only a transport failure makes Herdr unavailable. A remote error means
    /// Herdr answered, so it stays available for the next action.
    private func send(_ request: [String: JSONValue]) async throws -> [String: JSONValue] {
        do {
            let response = try await client.request(request)
            reportRecoveryIfNeeded()
            return response
        } catch let error as HerdrAPIError {
            reportRecoveryIfNeeded()
            throw error
        } catch {
            let description = String(describing: error)
            if lastTransportFailure != description {
                Log.logger.error("A Herdr request failed: \(description, privacy: .public).")
                lastTransportFailure = description
            }
            publish(state.withAvailability(.disconnected))
            throw error
        }
    }

    private func reportRecoveryIfNeeded() {
        guard lastTransportFailure != nil else { return }
        lastTransportFailure = nil
        Log.logger.info("Herdr is reachable again.")
    }

    /// The window may now show another machine, which this server's snapshot
    /// cannot confirm; a refresh still keeps Local's focus current.
    private func navigate(_ step: HerdrClientNavigation, count: Int) async throws {
        guard let navigator else {
            throw HerdrIntegrationError.unavailableState("Herdr window navigation is not configured.")
        }
        for _ in 0..<count {
            try await navigator.navigate(step)
        }
        try? await refresh()
    }

    /// Erases the previously typed option only when the focused pane's last
    /// line still ends with it, so text typed or submitted since is never erased.
    private func cycleText(_ options: [String]) async throws {
        try await refresh()
        guard let paneID = state.focusedPaneID else {
            throw HerdrIntegrationError.unavailableState("Herdr has no focused pane.")
        }
        var nextIndex = 0
        if let previous = textCycle, previous.paneID == paneID, previous.options == options {
            let screen = try encoder.decodePaneText(from: await send(encoder.readPaneRequest(paneID: paneID)))
            let prompt = screen.split(separator: "\n", omittingEmptySubsequences: false)
                .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            if prompt.hasSuffix(previous.text) {
                let erase = Array(repeating: "backspace", count: previous.text.count)
                _ = try await send(encoder.request(for: .sendKeys(paneID: paneID, keys: erase)))
                nextIndex = (previous.index + 1) % options.count
            }
        }
        let text = options[nextIndex]
        _ = try await send(encoder.request(for: .sendText(paneID: paneID, text: text)))
        textCycle = TextCycle(paneID: paneID, options: options, index: nextIndex, text: text)
    }
}

private struct TextCycle {
    let paneID: String
    let options: [String]
    let index: Int
    let text: String
}

/// How the adapter carries out one Herdr action.
public enum HerdrActionPlan: Sendable {
    /// Already names its Herdr target; sent as is.
    case direct(HerdrAction)
    /// Relative to Herdr's focus or ordering; resolved against a snapshot
    /// taken when the action runs.
    case fromCurrentState(@Sendable (HerdrState) throws -> HerdrAction)
    /// Reads and edits the focused pane over several requests.
    case cycleText(options: [String])
    /// Carried out by Herdr's window rather than its server, `count` times.
    case client(HerdrClientNavigation, count: Int)
}

public enum HerdrSemanticResolver {
    /// The one place that decides whether an action depends on Herdr's
    /// current state. The switch is exhaustive, so a new action cannot
    /// silently skip the press-time snapshot.
    public static func plan(for action: HerdrAction) -> HerdrActionPlan {
        switch action {
        case let .focusAgentSlot(slot):
            .fromCurrentState { try focusAgent(slot: slot, state: $0) }
        case .closeFocusedPane:
            .fromCurrentState { .closePane(id: try focusedPaneID(in: $0)) }
        case let .cycleTab(delta):
            .fromCurrentState { try cycleTab(delta: delta, state: $0) }
        case let .splitFocusedPane(direction):
            .fromCurrentState { .splitPane(id: try focusedPaneID(in: $0), direction: direction) }
        case let .cycleText(options):
            .cycleText(options: options)
        case let .cycleAgent(delta):
            .client(delta > 0 ? .nextAgent : .previousAgent, count: abs(delta))
        case let .cycleWorkspace(delta):
            .client(delta > 0 ? .nextWorkspace : .previousWorkspace, count: abs(delta))
        case .focusAgent, .closePane, .focusPane, .focusTab, .createWorkspace,
             .splitPane, .sendText, .sendKeys:
            .direct(action)
        }
    }

    private static func focusAgent(slot: Int, state: HerdrState) throws -> HerdrAction {
        guard slot > 0, slot <= state.agents.count else {
            throw HerdrIntegrationError.slotOutOfBounds(slot: slot, available: state.agents.count)
        }
        let agent = state.agents[slot - 1]
        return .focusAgent(target: agent.name ?? agent.paneID)
    }

    private static func focusedPaneID(in state: HerdrState) throws -> String {
        guard let paneID = state.focusedPaneID else {
            throw HerdrIntegrationError.unavailableState("Herdr has no focused pane.")
        }
        return paneID
    }

    private static func cycleTab(delta: Int, state: HerdrState) throws -> HerdrAction {
        guard !state.tabs.isEmpty else {
            throw HerdrIntegrationError.unavailableState("Herdr has no tabs.")
        }
        guard let currentIndex = state.tabs.firstIndex(where: {
            $0.id == state.focusedTabID || (state.focusedTabID == nil && $0.focused)
        }) else {
            throw HerdrIntegrationError.unavailableState("Herdr has no focused tab.")
        }
        let count = state.tabs.count
        let nextIndex = ((currentIndex + delta) % count + count) % count
        return .focusTab(id: state.tabs[nextIndex].id)
    }
}

public extension HerdrAdapter {
    /// A refresh of an available Herdr keeps it available while in flight, so
    /// actions are not rejected during routine polling.
    func refresh() async throws {
        if !hasStartedRefresh {
            hasStartedRefresh = true
            publish(state.withAvailability(.connecting))
        }
        let response = try await send(encoder.snapshotRequest())
        let snapshot = try encoder.decodeSnapshot(from: response)
        publish(HerdrState(
            availability: .available,
            panes: snapshot.panes,
            tabs: snapshot.tabs,
            workspaces: snapshot.workspaces ?? [],
            agents: snapshot.agents.inSlotOrder(slotPriority),
            focusedPaneID: snapshot.focusedPaneID,
            focusedTabID: snapshot.focusedTabID
        ))
    }

    func execute(_ invocation: ActionInvocation) async throws {
        try await execute(HerdrActions.decode(invocation))
    }

    func states() -> AsyncStream<HerdrState> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }

    func isAvailable() -> Bool { state.availability == .available }

    /// Accepts a state decoded by a documented Herdr state codec.
    func accept(_ newState: HerdrState) {
        publish(newState)
    }

    private func publish(_ newState: HerdrState) {
        guard newState != state else { return }
        state = newState
        observers.values.forEach { $0.yield(newState) }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}

private extension [HerdrAgent] {
    func inSlotOrder(_ priority: [String]) -> [HerdrAgent] {
        func rank(_ status: String) -> Int {
            priority.firstIndex(of: status) ?? priority.firstIndex(of: "unknown") ?? priority.count
        }
        return enumerated()
            .sorted { (rank($0.element.status), $0.offset) < (rank($1.element.status), $1.offset) }
            .map(\.element)
    }
}

private extension HerdrState {
    func withAvailability(_ availability: HerdrAvailability) -> HerdrState {
        HerdrState(
            availability: availability,
            panes: panes,
            tabs: tabs,
            workspaces: workspaces,
            agents: agents,
            focusedPaneID: focusedPaneID,
            focusedTabID: focusedTabID
        )
    }
}

public actor RecordingHerdrController: HerdrControlling {
    private var recordedActions: [HerdrAction] = []
    private var state: HerdrState

    public init(initialState: HerdrState = .disconnected) {
        state = initialState
    }

    public func execute(_ action: HerdrAction) {
        recordedActions.append(action)
    }

    public func actions() -> [HerdrAction] { recordedActions }

    public func states() -> AsyncStream<HerdrState> {
        let current = state
        return AsyncStream { continuation in
            continuation.yield(current)
            continuation.finish()
        }
    }

    public func isAvailable() -> Bool { state.availability == .available }
}

public actor RecordingHerdrClientNavigator: HerdrClientNavigating {
    private var recordedSteps: [HerdrClientNavigation] = []

    public init() {}

    public func navigate(_ step: HerdrClientNavigation) {
        recordedSteps.append(step)
    }

    public func steps() -> [HerdrClientNavigation] { recordedSteps }
}
