import XCTest
@testable import DispatchCore

final class ActionRegistryTests: XCTestCase {
    func testRegistryExecutesRegistrationWithValidatedInvocation() async throws {
        let recorder = InvocationRecorder()
        let registration = ActionRegistration(definition: definition(id: "test.record")) { invocation in
            await recorder.append(invocation)
        }
        let registry = try ActionRegistry(registrations: [registration])
        let invocation = try registry.catalog.makeInvocation(id: "test.record")

        try await registry.execute(invocation)

        let values = await recorder.values
        XCTAssertEqual(values, [invocation])
    }

    func testRegistryDistinguishesUnavailableAndFailed() async throws {
        let unavailable = ActionRegistration(
            definition: definition(id: "test.unavailable"),
            isAvailable: { false },
            handler: { _ in XCTFail("Unavailable handler must not run") }
        )
        let failed = ActionRegistration(definition: definition(id: "test.failed")) { _ in
            throw TestFailure.expected
        }
        let registry = try ActionRegistry(registrations: [unavailable, failed])

        do {
            try await registry.execute(try registry.catalog.makeInvocation(id: "test.unavailable"))
            XCTFail("Expected unavailable")
        } catch {
            XCTAssertEqual(error as? ActionExecutionError, .unavailable("test.unavailable"))
        }

        do {
            try await registry.execute(try registry.catalog.makeInvocation(id: "test.failed"))
            XCTFail("Expected failure")
        } catch let error as ActionExecutionError {
            guard case let .failed(action, message) = error else {
                return XCTFail("Expected failed, got \(error)")
            }
            XCTAssertEqual(action, "test.failed")
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testRegistryRejectsDuplicateRegistration() {
        let first = ActionRegistration(definition: definition(id: "test.same")) { _ in }
        let second = ActionRegistration(definition: definition(id: "test.same")) { _ in }

        XCTAssertThrowsError(try ActionRegistry(registrations: [first, second])) {
            XCTAssertEqual($0 as? ActionCatalogError, .duplicateAction("test.same"))
        }
    }

    func testRegistryDefensivelyRejectsDecodedInvalidInvocation() async throws {
        let definition = ActionDefinition(
            id: "test.needsValue",
            title: "Needs value",
            summary: "Test",
            arguments: [
                ActionArgumentDefinition(name: "value", type: .integer, summary: "Value")
            ]
        )
        let registry = try ActionRegistry(registrations: [
            ActionRegistration(definition: definition) { _ in
                XCTFail("Invalid invocation must not run")
            }
        ])
        let invalid = try JSONDecoder().decode(
            ActionInvocation.self,
            from: Data(#"{"id":"test.needsValue","arguments":{}}"#.utf8)
        )

        do {
            try await registry.execute(invalid)
            XCTFail("Expected invalid invocation")
        } catch let error as ActionExecutionError {
            guard case let .invalidInvocation(action, _) = error else {
                return XCTFail("Expected invalid invocation, got \(error)")
            }
            XCTAssertEqual(action, "test.needsValue")
        }
    }

    private func definition(id: ActionID) -> ActionDefinition {
        ActionDefinition(id: id, title: id.rawValue, summary: "Test")
    }

    func testExecutionErrorsDescribeThemselvesReadably() {
        XCTAssertEqual(
            String(describing: ActionExecutionError.unavailable("test.unavailable")),
            "The integration is not available right now."
        )
        XCTAssertEqual(
            String(describing: ActionExecutionError.unsupported("test.x")),
            "No integration handles this action."
        )
        XCTAssertEqual(
            String(describing: ActionExecutionError.invalidInvocation(action: "test.x", message: "slot is missing")),
            "Invalid arguments: slot is missing"
        )
        XCTAssertEqual(String(describing: ActionExecutionError.failed(action: "test.x", message: "Boom.")), "Boom.")
    }
}

private actor InvocationRecorder {
    private(set) var values: [ActionInvocation] = []

    func append(_ invocation: ActionInvocation) {
        values.append(invocation)
    }
}

private enum TestFailure: Error {
    case expected
}
