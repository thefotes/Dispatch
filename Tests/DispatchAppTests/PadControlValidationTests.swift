@testable import DispatchApp
import DispatchCore
import DispatchRuntime
import Foundation
import XCTest

final class PadControlValidationTests: XCTestCase {
    func testBindingOnTheWideKeysSecondSwitchIsRejected() async throws {
        let message = try await loadFailure(#"""
        {"version":1,"bindings":[
          {"when":{"control":{"type":"key","index":12},"gesture":{"type":"pressed"}},
           "actions":[{"id":"herdr.pane.closeFocused"}]},
          {"when":{"control":{"type":"key","index":11},"gesture":{"type":"pressed"}},
           "actions":[{"id":"herdr.pane.closeFocused"}]}
        ]}
        """#)

        XCTAssertEqual(
            message,
            "At bindings[1].when.control.index: The pad has no key 11. Its keys are 0–10 and 12. "
                + "The wide key is key 10."
        )
    }

    func testLightsOnlyGoOnKeysWithLights() async throws {
        let unlit = [#"{"type":"key","index":12}"#, #"{"type":"dial"}"#, #"{"type":"key","index":13}"#]
        for control in unlit {
            let message = try await loadFailure(#"""
            {"version":1,"bindings":[],"lights":[
              {"control":{"type":"key","index":10},"appearance":{"color":{"red":1,"green":2,"blue":3}}},
              {"control":\#(control),"appearance":{"color":{"red":1,"green":2,"blue":3}}}
            ]}
            """#)

            XCTAssertTrue(message.hasPrefix("At lights[1].control: The pad cannot light"), message)
            XCTAssertTrue(message.hasSuffix("Only keys 0–10 have lights."), message)
        }
    }

    func testDefaultConfigurationPasses() {
        XCTAssertNoThrow(try PadControlValidation.validate(DefaultConfiguration.value))
    }

    /// The message the menu-bar panel shows when the file fails to load.
    private func loadFailure(_ json: String) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        let loader = ValidatingConfigurationLoader(file: FileConfigurationLoader(url: url))
        do {
            _ = try await loader.load()
        } catch {
            return ConfigurationDiagnostic.message(for: error)
        }
        XCTFail("Expected the configuration to be rejected")
        return ""
    }
}
