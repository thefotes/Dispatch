import XCTest
@testable import WLKit

final class KeyBindingsTests: XCTestCase {

    private func parse(_ json: String) -> KeyBindings {
        KeyBindings.parse(Data(json.utf8))
    }

    func testMissingFileMeansDefaults() {
        let bindings = KeyBindings()
        XCTAssertEqual(bindings.text(for: 8), "Open PRs for all active GitButler branches")
        XCTAssertEqual(bindings.text(for: 12), "Run but pull")
        XCTAssertNil(bindings.text(for: 10), "the wide key defaults to voice, not text")
        XCTAssertNil(bindings.text(for: 11))
    }

    func testFileOverridesAKeyAndKeepsTheOtherDefault() {
        let bindings = parse(#"{"keys": {"8": "Ship it"}}"#)
        XCTAssertEqual(bindings.text(for: 8), "Ship it")
        XCTAssertEqual(bindings.text(for: 12), "Run but pull")
    }

    /// "10+11" is the wide key spoken of as one: both halves get the string.
    func testWideKeyBindsBothHalvesTogether() {
        let bindings = parse(#"{"keys": {"10+11": "Summarise your progress"}}"#)
        XCTAssertEqual(bindings.text(for: 10), "Summarise your progress")
        XCTAssertEqual(bindings.text(for: 11), "Summarise your progress")
    }

    func testWideKeyHalvesCanDiffer() {
        let bindings = parse(#"{"keys": {"10": "left half", "11": "right half"}}"#)
        XCTAssertEqual(bindings.text(for: 10), "left half")
        XCTAssertEqual(bindings.text(for: 11), "right half")
    }

    /// An empty string unbinds: the key goes dark rather than typing nothing.
    func testEmptyStringUnbindsADefault() {
        let bindings = parse(#"{"keys": {"12": ""}}"#)
        XCTAssertNil(bindings.text(for: 12))
        XCTAssertEqual(bindings.text(for: 8), "Open PRs for all active GitButler branches")
    }

    func testMalformedFileFallsBackToDefaults() {
        XCTAssertEqual(parse("not json"), KeyBindings())
        XCTAssertEqual(parse(#"{"keys": "nope"}"#), KeyBindings())
    }

    func testClaudeModelAndEffortListsHaveDefaults() {
        let bindings = KeyBindings()
        XCTAssertEqual(bindings.claudeModels, ["fable", "opus", "sonnet", "haiku"])
        XCTAssertEqual(bindings.claudeEfforts, ["low", "medium", "high", "xhigh", "max"])
    }

    func testClaudeListsAreOverridable() {
        let bindings = parse(#"{"claude": {"models": ["opus", "sonnet"], "efforts": ["low", "high"]}}"#)
        XCTAssertEqual(bindings.claudeModels, ["opus", "sonnet"])
        XCTAssertEqual(bindings.claudeEfforts, ["low", "high"])
        XCTAssertEqual(bindings.text(for: 8), "Open PRs for all active GitButler branches",
                       "key defaults survive a claude-only config")
    }

    func testEmptyClaudeListsFallBackToDefaults() {
        let bindings = parse(#"{"claude": {"models": []}}"#)
        XCTAssertEqual(bindings.claudeModels, KeyBindings.defaultClaudeModels)
    }
}
