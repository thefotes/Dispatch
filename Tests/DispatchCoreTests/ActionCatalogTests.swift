import XCTest
@testable import DispatchCore

final class ActionCatalogTests: XCTestCase {
    func testCatalogSortsDefinitionsAndBuildsValidatedInvocation() throws {
        let catalog = try ActionCatalog(definitions: [
            definition(id: "keyboard.type", arguments: [
                ActionArgumentDefinition(
                    name: "text",
                    type: .string,
                    summary: "Text to type"
                ),
                ActionArgumentDefinition(
                    name: "interval",
                    type: .number,
                    required: false,
                    summary: "Delay"
                )
            ]),
            definition(id: "herdr.closeFocusedPane")
        ])

        XCTAssertEqual(catalog.definitions.map(\.id.rawValue), [
            "herdr.closeFocusedPane",
            "keyboard.type"
        ])
        let invocation = try catalog.makeInvocation(
            id: "keyboard.type",
            arguments: ["text": .string("hello"), "interval": .integer(1)]
        )
        XCTAssertEqual(invocation.id, "keyboard.type")
        XCTAssertEqual(invocation.arguments["text"], .string("hello"))
    }

    func testCatalogRejectsInvalidAndDuplicateDefinitions() throws {
        XCTAssertThrowsError(try ActionCatalog(definitions: [definition(id: "notNamespaced")])) {
            XCTAssertEqual(
                $0 as? ActionCatalogError,
                .invalidActionID("notNamespaced")
            )
        }
        XCTAssertThrowsError(try ActionCatalog(definitions: [
            definition(id: "herdr.close"),
            definition(id: "herdr.close")
        ])) {
            XCTAssertEqual($0 as? ActionCatalogError, .duplicateAction("herdr.close"))
        }
    }

    func testCatalogRejectsMissingUnknownAndWrongTypeArguments() throws {
        let catalog = try ActionCatalog(definitions: [definition(id: "keyboard.type", arguments: [
            ActionArgumentDefinition(name: "text", type: .string, summary: "Text")
        ])])

        XCTAssertThrowsError(try catalog.makeInvocation(id: "keyboard.type")) {
            XCTAssertEqual($0 as? ActionValidationError, .missingArgument("text"))
        }
        XCTAssertThrowsError(
            try catalog.makeInvocation(
                id: "keyboard.type",
                arguments: ["text": .string("x"), "other": .string("x")]
            )
        ) {
            XCTAssertEqual($0 as? ActionValidationError, .unknownArgument("other"))
        }
        XCTAssertThrowsError(
            try catalog.makeInvocation(id: "keyboard.type", arguments: ["text": .boolean(true)])
        ) {
            XCTAssertEqual(
                $0 as? ActionValidationError,
                .invalidArgumentType(name: "text", expected: .string)
            )
        }
    }

    func testInvocationRoundTripsThroughJSON() throws {
        let catalog = try ActionCatalog(definitions: [definition(id: "herdr.focus", arguments: [
            ActionArgumentDefinition(name: "slot", type: .integer, summary: "Slot")
        ])])
        let invocation = try catalog.makeInvocation(
            id: "herdr.focus",
            arguments: ["slot": .integer(3)]
        )

        let data = try JSONEncoder().encode(invocation)
        let decoded = try JSONDecoder().decode(ActionInvocation.self, from: data)

        XCTAssertEqual(decoded, invocation)
    }

    private func definition(
        id: ActionID,
        arguments: [ActionArgumentDefinition] = []
    ) -> ActionDefinition {
        ActionDefinition(id: id, title: id.rawValue, summary: "Test action", arguments: arguments)
    }
}
