@testable import DispatchApp
import DispatchCore
import DispatchMacOS
import DispatchProviders
import DispatchRuntime
import Foundation
import XCTest

final class KeyboardHerdrClientNavigatorTests: XCTestCase {
    func testConfiguredTerminalIsActivatedBeforeNavigationKey() async throws {
        let settings = try settings(#"{"terminalBundleIdentifier":"com.apple.Terminal"}"#)
        let automation = RecordingMacOSAutomation()
        let navigator = KeyboardHerdrClientNavigator(automation: automation, settings: { settings })

        try await navigator.navigate(.nextWorkspace)

        let operations = await automation.recordedOperations()
        XCTAssertEqual(operations, [
            .macro([
                .activate(ApplicationTarget(bundleIdentifier: "com.apple.Terminal")),
                .shortcut(KeyboardShortcut(key: .f18))
            ])
        ])
    }

    func testMissingTerminalDefaultsToGhostty() async throws {
        let configuration = try JSONDecoder().decode(
            DispatchConfiguration.self,
            from: Data(#"{"version":1,"bindings":[]}"#.utf8)
        )
        let settings = try HerdrTerminalConfiguration(configuration)
        let automation = RecordingMacOSAutomation()
        let navigator = KeyboardHerdrClientNavigator(automation: automation, settings: { settings })

        try await navigator.navigate(.nextAgent)

        let operations = await automation.recordedOperations()
        XCTAssertEqual(operations, [
            .macro([
                .activate(ApplicationTarget(bundleIdentifier: "com.mitchellh.ghostty")),
                .shortcut(KeyboardShortcut(key: .f19))
            ])
        ])
    }

    func testInvalidTerminalReportsItsConfigurationPath() async throws {
        let message = try await loadFailure(#"{"terminalBundleIdentifier":"not a bundle id"}"#)

        XCTAssertTrue(message.contains("integrations.herdr.terminalBundleIdentifier"), message)
    }

    func testEachStepBringsTheTerminalForwardBeforePressingItsHerdrKey() async throws {
        let automation = RecordingMacOSAutomation()
        let settings = try settings(#"{"terminalBundleIdentifier":"com.example.Terminal"}"#)
        let terminal = ApplicationTarget(bundleIdentifier: "com.example.Terminal")
        let navigator = KeyboardHerdrClientNavigator(automation: automation, settings: { settings })

        try await navigator.navigate(.previousAgent)
        try await navigator.navigate(.previousWorkspace)
        try await navigator.navigate(.nextWorkspace)
        try await navigator.navigate(.nextAgent)

        let operations = await automation.recordedOperations()
        XCTAssertEqual(operations, [KeyboardKey.f16, .f17, .f18, .f19].map { key in
            .macro([.activate(terminal), .shortcut(KeyboardShortcut(key: key))])
        })
    }

    func testConfiguredWindowKeysReplaceOnlyTheStepsTheyName() async throws {
        let settings = try settings(#"""
        {"windowKeys":{
          "nextAgent":{"key":"f13"},
          "previousAgent":{"key":"j","modifiers":["control","option"]}
        }}
        """#)
        let automation = RecordingMacOSAutomation()
        let navigator = KeyboardHerdrClientNavigator(automation: automation, settings: { settings })

        try await navigator.navigate(.previousAgent)
        try await navigator.navigate(.previousWorkspace)
        try await navigator.navigate(.nextWorkspace)
        try await navigator.navigate(.nextAgent)

        let ghostty = ApplicationTarget(bundleIdentifier: "com.mitchellh.ghostty")
        let operations = await automation.recordedOperations()
        XCTAssertEqual(operations, [
            KeyboardShortcut(key: .j, modifiers: [.control, .option]),
            KeyboardShortcut(key: .f17),
            KeyboardShortcut(key: .f18),
            KeyboardShortcut(key: .f13)
        ].map { .macro([.activate(ghostty), .shortcut($0)]) })
    }

    func testTwoStepsSharingAKeyAreRejected() async throws {
        let message = try await loadFailure(#"{"windowKeys":{"nextAgent":{"key":"f17"}}}"#)

        XCTAssertEqual(
            message,
            "At integrations.herdr.windowKeys.nextAgent: previousWorkspace already uses this key. "
                + "Give each step its own key."
        )
    }

    func testInvalidWindowKeysReportTheirPath() async throws {
        let cases = [
            (#"{"windowKeys":{"nextTab":{"key":"f13"}}}"#, "integrations.herdr.windowKeys.nextTab"),
            (#"{"windowKeys":{"nextAgent":{"key":"f20"}}}"#, "integrations.herdr.windowKeys.nextAgent.key"),
            (#"{"windowKeys":{"nextAgent":"f13"}}"#, "integrations.herdr.windowKeys.nextAgent"),
            (
                #"{"windowKeys":{"nextAgent":{"key":"f13","modifiers":["hyper"]}}}"#,
                "integrations.herdr.windowKeys.nextAgent.modifiers"
            ),
            (
                #"{"windowKeys":{"nextAgent":{"key":"f13","repeat":2}}}"#,
                "integrations.herdr.windowKeys.nextAgent.repeat"
            )
        ]
        for (herdr, path) in cases {
            let message = try await loadFailure(herdr)
            XCTAssertTrue(message.hasPrefix("At \(path):"), message)
        }
    }

    private func settings(_ herdr: String) throws -> HerdrTerminalConfiguration {
        let configuration = try JSONDecoder().decode(
            DispatchConfiguration.self,
            from: Data(#"{"version":1,"bindings":[],"integrations":{"herdr":\#(herdr)}}"#.utf8)
        )
        return try HerdrTerminalConfiguration(configuration)
    }

    /// The message the menu-bar panel shows when the file fails to load.
    private func loadFailure(_ herdr: String) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"version":1,"bindings":[],"integrations":{"herdr":\#(herdr)}}"#.utf8).write(to: url)
        let loader = ValidatingConfigurationLoader(file: FileConfigurationLoader(url: url))
        do {
            _ = try await loader.load()
        } catch {
            return ConfigurationDiagnostic.message(for: error)
        }
        XCTFail("Expected \(herdr) to be rejected")
        return ""
    }
}
