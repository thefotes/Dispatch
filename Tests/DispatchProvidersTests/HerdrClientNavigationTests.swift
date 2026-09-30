import DispatchCore
import DispatchProviders
import Foundation
import XCTest

final class HerdrClientNavigationTests: XCTestCase {
    func testDecodesWindowCycleActionsAndRejectsAZeroDelta() throws {
        XCTAssertEqual(
            try HerdrActions.decode(invocation(id: "herdr.agent.cycle", arguments: ["delta": .integer(-1)])),
            .cycleAgent(delta: -1)
        )
        XCTAssertEqual(
            try HerdrActions.decode(invocation(id: "herdr.workspace.cycle", arguments: ["delta": .integer(2)])),
            .cycleWorkspace(delta: 2)
        )
        XCTAssertThrowsError(try HerdrActions.decode(invocation(
            id: "herdr.agent.cycle", arguments: ["delta": .integer(0)]
        ))) { error in
            XCTAssertEqual(
                error as? HerdrIntegrationError,
                .invalidArgument(action: HerdrActions.cycleAgent, name: "delta")
            )
        }
    }

    func testWindowCyclesStepTheWindowOncePerUnitOfDelta() async throws {
        let navigator = RecordingHerdrClientNavigator()
        let adapter = makeAdapter(navigator: navigator)

        try await adapter.execute(.cycleAgent(delta: -2))
        try await adapter.execute(.cycleWorkspace(delta: 1))

        let steps = await navigator.steps()
        XCTAssertEqual(steps, [.previousAgent, .previousAgent, .nextWorkspace])
    }

    func testWindowCyclesAreUnavailableWithoutANavigator() async throws {
        let adapter = makeAdapter(navigator: nil)

        do {
            try await adapter.execute(.cycleAgent(delta: 1))
            XCTFail("Expected window navigation to be unavailable")
        } catch let error as HerdrIntegrationError {
            XCTAssertEqual(error, .unavailableState("Herdr window navigation is not configured."))
        }
    }

    /// Window navigation never needs Herdr's server, so no server listens.
    private func makeAdapter(navigator: (any HerdrClientNavigating)?) -> HerdrAdapter {
        HerdrAdapter(
            client: HerdrUnixSocketClient(configuration: .init(
                socketPath: "/tmp/dispatch-herdr-absent-\(UUID().uuidString).sock",
                timeout: .milliseconds(100)
            )),
            encoder: HerdrProtocol22Codec(),
            navigator: navigator
        )
    }

    private func invocation(id: String, arguments: [String: JSONValue] = [:]) throws -> ActionInvocation {
        let payload: JSONValue = .object(["id": .string(id), "arguments": .object(arguments)])
        return try JSONDecoder().decode(ActionInvocation.self, from: JSONEncoder().encode(payload))
    }
}
