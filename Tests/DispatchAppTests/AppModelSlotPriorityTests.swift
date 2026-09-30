@testable import DispatchApp
import DispatchCore
import DispatchCreatorMicro
import DispatchProviders
import DispatchRuntime
import DispatchTestSupport
import Foundation
import XCTest

@MainActor
final class AppModelSlotPriorityTests: XCTestCase {
    func testAgentsTakeSlotsInTheConfiguredStatusPriority() async throws {
        let herdr = HerdrAdapter(
            client: TwoAgentHerdrClient(),
            encoder: HerdrProtocol22Codec(),
            slotPriority: HerdrPresentationRenderer.defaultPalette.ambientPriority
        )
        let pad = FakePadDevice()
        pad.setConnectionError(.connectionFailed)
        let palette = StatusPalette(
            appearances: HerdrPresentationRenderer.defaultPalette.appearances,
            ambientPriority: ["working", "done"]
        )
        let runtime = try DispatchRuntime(
            pad: pad,
            registrations: [],
            configurationLoader: StaticConfigurationLoader(
                DispatchConfiguration(bindings: [], statusPalette: palette)
            )
        )
        let model = AppModel(
            inputMonitoringRequester: GrantedRequester(),
            herdr: herdr,
            runtime: runtime,
            herdrPollInterval: .milliseconds(20)
        )

        await model.start()
        defer { Task { await model.stop() } }

        for _ in 0..<100 where model.herdrState.agents.map(\.paneID) != ["working", "done"] {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.herdrState.agents.map(\.paneID), ["working", "done"])
    }
}

/// Herdr lists the done agent first, which the default priority keeps.
private actor TwoAgentHerdrClient: HerdrConnecting {
    func request(_ body: [String: JSONValue]) async throws -> [String: JSONValue] {
        ["result": .object([
            "type": .string("session_snapshot"),
            "snapshot": .object([
                "version": .string("0.9.1"),
                "protocol": .integer(22),
                "panes": .array([]),
                "tabs": .array([]),
                "agents": .array(["done", "working"].map { status in
                    .object([
                        "pane_id": .string(status),
                        "agent_status": .string(status),
                        "focused": .boolean(false)
                    ])
                })
            ])
        ])]
    }
}

private actor GrantedRequester: InputMonitoringPermissionRequesting {
    func check() async -> InputMonitoringPermission { .granted }
    func request() async -> InputMonitoringPermission { .granted }
}
