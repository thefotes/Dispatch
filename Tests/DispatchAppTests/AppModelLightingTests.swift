@testable import DispatchApp
import DispatchCore
import DispatchCreatorMicro
import DispatchProviders
import DispatchRuntime
import DispatchTestSupport
import Foundation
import XCTest

@MainActor
final class AppModelLightingTests: XCTestCase {
    /// A failed action leaves the runtime degraded until the next action
    /// succeeds. The lights must still follow Herdr in the meantime.
    func testLightsFollowHerdrWhileAnActionFailureShows() async throws {
        let herdrClient = OneAgentHerdrClient(status: "working")
        let herdr = HerdrAdapter(
            client: herdrClient,
            encoder: HerdrProtocol22Codec(),
            slotPriority: HerdrPresentationRenderer.defaultPalette.ambientPriority
        )
        let pad = FakePadDevice()
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [Self.failingAction],
            configurationLoader: StaticConfigurationLoader(DispatchConfiguration(bindings: [
                BindingDefinition(
                    event: EventPattern(control: .key(1), gesture: .pressed),
                    actions: [ConfiguredAction(id: Self.failingAction.definition.id)]
                )
            ]))
        )
        let model = AppModel(
            inputMonitoringRequester: GrantedPermission(),
            herdr: herdr,
            runtime: runtime,
            herdrPollInterval: .milliseconds(20)
        )
        await model.start()
        defer { Task { await model.stop() } }
        try await waitUntil { pad.recordedPresentations().last?.ambient?.color == Self.working }

        pad.emit(DispatchEvent(
            source: DeviceIdentity(rawValue: "test-pad"),
            control: .key(1),
            gesture: .pressed,
            timestamp: Date()
        ))
        try await waitUntil {
            if case .action? = await runtime.currentSnapshot().issue { true } else { false }
        }
        await herdrClient.setStatus("blocked")

        try await waitUntil { pad.recordedPresentations().last?.ambient?.color == Self.blocked }
        XCTAssertEqual(pad.recordedPresentations().last?.ambient?.color, Self.blocked)
    }

    private static let working = DispatchCore.RGBColor(red: 30, green: 145, blue: 255)
    private static let blocked = DispatchCore.RGBColor(red: 255, green: 45, blue: 65)

    private static let failingAction = ActionRegistration(
        definition: ActionDefinition(id: "test.fail", title: "Fail", summary: "Always fails")
    ) { _ in
        throw ActionFailure()
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<100 where !(await condition()) {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct ActionFailure: Error {}

private actor OneAgentHerdrClient: HerdrConnecting {
    private var status: String

    init(status: String) {
        self.status = status
    }

    func setStatus(_ status: String) {
        self.status = status
    }

    func request(_ body: [String: JSONValue]) async throws -> [String: JSONValue] {
        ["result": .object([
            "type": .string("session_snapshot"),
            "snapshot": .object([
                "version": .string("0.9.3"),
                "protocol": .integer(22),
                "panes": .array([]),
                "tabs": .array([]),
                "agents": .array([.object([
                    "pane_id": .string("agent"),
                    "agent_status": .string(status),
                    "focused": .boolean(false)
                ])])
            ])
        ])]
    }
}

private actor GrantedPermission: InputMonitoringPermissionRequesting {
    func check() async -> InputMonitoringPermission { .granted }
    func request() async -> InputMonitoringPermission { .granted }
}
