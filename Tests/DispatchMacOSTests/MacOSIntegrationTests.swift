import DispatchCore
import DispatchMacOS
import Foundation
import XCTest

final class MacOSIntegrationTests: XCTestCase {
    func testCatalogDescribesGenericMacOSCapabilities() throws {
        let catalog = try ActionCatalog(definitions: MacOSActions.definitions)
        XCTAssertNotNil(catalog.definition(for: "keyboard.shortcut"))
        XCTAssertNotNil(catalog.definition(for: "keyboard.typeText"))
        XCTAssertNotNil(catalog.definition(for: "application.activate"))
        XCTAssertNotNil(catalog.definition(for: "application.focusWindow"))
        XCTAssertNotNil(catalog.definition(for: "macro.sequence"))
    }

    func testDecodesKeyboardShortcut() throws {
        let shortcutInvocation = try invocation(
            id: "keyboard.shortcut",
            arguments: [
                "key": .string("k"),
                "modifiers": .array([.string("command"), .string("shift")])
            ]
        )
        XCTAssertEqual(
            try MacOSActions.decode(shortcutInvocation),
            .shortcut(.init(key: .k, modifiers: [.command, .shift]))
        )
        XCTAssertEqual(
            try MacOSActions.decode(invocation(
                id: "keyboard.shortcut",
                arguments: ["key": .string("rightCommand")]
            )),
            .shortcut(.init(key: .rightCommand))
        )
        XCTAssertEqual(
            try MacOSActions.decode(invocation(id: "keyboard.shortcut", arguments: ["key": .string("f19")])),
            .shortcut(.init(key: .f19))
        )
    }

    func testDecodesTextAndApplicationOperations() throws {
        XCTAssertEqual(
            try MacOSActions.decode(invocation(id: "keyboard.typeText", arguments: ["text": .string("hello")])),
            .typeText("hello")
        )
        XCTAssertEqual(
            try MacOSActions.decode(invocation(
                id: "application.activate",
                arguments: ["bundleIdentifier": .string("com.example.App")]
            )),
            .activate(.init(bundleIdentifier: "com.example.App"))
        )
    }

    func testDecodesOrderedMacro() throws {
        let invocation = try invocation(
            id: "macro.sequence",
            arguments: [
                "operations": .array([
                    .object(["action": .string("keyboard.typeText"), "text": .string("go")]),
                    .object(["action": .string("macro.wait"), "milliseconds": .integer(25)]),
                    .object([
                        "action": .string("keyboard.shortcut"),
                        "key": .string("return"),
                        "modifiers": .array([])
                    ])
                ])
            ]
        )
        XCTAssertEqual(
            try MacOSActions.decode(invocation),
            .macro([.typeText("go"), .wait(.milliseconds(25)), .shortcut(.init(key: .returnKey))])
        )
    }

    func testRejectsUnknownKeysAndMalformedMacros() throws {
        XCTAssertThrowsError(try MacOSActions.decode(invocation(
            id: "keyboard.shortcut",
            arguments: ["key": .string("not-a-key")]
        )))
        XCTAssertThrowsError(try MacOSActions.decode(invocation(
            id: "macro.sequence",
            arguments: ["operations": .array([.object(["action": .string("shell.run")])])]
        )))
    }

    func testRecordingAutomationDoesNotControlComputer() async throws {
        let automation = RecordingMacOSAutomation(permission: .denied)
        await automation.perform(.typeText("safe"))
        await automation.perform(.shortcut(.init(key: .k, modifiers: [.command])))
        let permission = await automation.accessibilityPermission(promptIfNeeded: true)

        XCTAssertEqual(permission, .denied)
        let operations = await automation.recordedOperations()
        XCTAssertEqual(operations, [.typeText("safe"), .shortcut(.init(key: .k, modifiers: [.command]))])
        let checks = await automation.recordedPermissionChecks()
        XCTAssertEqual(checks, [true])
    }

    func testRegistrationsExecuteThroughRecordingBoundary() async throws {
        let automation = RecordingMacOSAutomation()
        let registry = try ActionRegistry(registrations: MacOSActions.registrations(automation: automation))
        try await registry.execute(invocation(id: "keyboard.typeText", arguments: ["text": .string("safe")]))
        let operations = await automation.recordedOperations()
        XCTAssertEqual(operations, [.typeText("safe")])
    }

    func testRegistrationsUseAccessibilityPermissionAsAvailability() async throws {
        let automation = RecordingMacOSAutomation(permission: .denied)
        let registry = try ActionRegistry(registrations: MacOSActions.registrations(automation: automation))
        do {
            try await registry.execute(invocation(id: "application.focusWindow", arguments: [
                "bundleIdentifier": .string("com.example.App"),
                "title": .string("Window")
            ]))
            XCTFail("Expected unavailable action")
        } catch let error as ActionExecutionError {
            XCTAssertEqual(error, .unavailable(MacOSActions.focusWindow))
        }
    }

    private func invocation(id: String, arguments: [String: JSONValue] = [:]) throws -> ActionInvocation {
        let data = try JSONEncoder().encode(MacInvocationPayload(id: id, arguments: arguments))
        return try JSONDecoder().decode(ActionInvocation.self, from: data)
    }
}

private struct MacInvocationPayload: Encodable {
    let id: String
    let arguments: [String: JSONValue]
}
