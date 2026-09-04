import XCTest
@testable import WLKit

/// Parsing for config-bound keyboard shortcuts ("cmd+shift+5"). Posting the
/// synthesised event is app-layer (needs AppKit); this is the pure half.
final class ShortcutSpecTests: XCTestCase {

    func testParsesABareKey() {
        let spec = ShortcutSpec.parse("5")
        XCTAssertEqual(spec?.keyCode, 23)
        XCTAssertEqual(spec?.modifiers, [])
    }

    func testParsesModifiersInAnyOrder() {
        XCTAssertEqual(ShortcutSpec.parse("cmd+shift+5"), ShortcutSpec.parse("shift+cmd+5"))
    }

    func testParsesAllFourModifiers() {
        let spec = ShortcutSpec.parse("cmd+shift+ctrl+alt+5")
        XCTAssertEqual(spec?.modifiers, [.command, .shift, .control, .option])
    }

    func testAcceptsAliasesForModifiers() {
        XCTAssertEqual(ShortcutSpec.parse("command+option+5"), ShortcutSpec.parse("cmd+alt+5"))
        XCTAssertEqual(ShortcutSpec.parse("control+5"), ShortcutSpec.parse("ctrl+5"))
    }

    func testIsCaseInsensitive() {
        XCTAssertEqual(ShortcutSpec.parse("CMD+SHIFT+5"), ShortcutSpec.parse("cmd+shift+5"))
    }

    func testParsesNamedKeys() {
        XCTAssertEqual(ShortcutSpec.parse("f13")?.keyCode, 105)
        XCTAssertEqual(ShortcutSpec.parse("up")?.keyCode, 126)
        XCTAssertEqual(ShortcutSpec.parse("space")?.keyCode, 49)
        XCTAssertEqual(ShortcutSpec.parse("escape")?.keyCode, 53)
    }

    func testRejectsAnUnknownKeyName() {
        XCTAssertNil(ShortcutSpec.parse("cmd+banana"))
    }

    func testRejectsMoreThanOneBaseKey() {
        XCTAssertNil(ShortcutSpec.parse("5+6"))
    }

    func testRejectsAModifierOnlySpec() {
        XCTAssertNil(ShortcutSpec.parse("cmd+shift"))
    }

    func testRejectsAnEmptySpec() {
        XCTAssertNil(ShortcutSpec.parse(""))
    }

    func testToleratesStraySpaces() {
        XCTAssertEqual(ShortcutSpec.parse(" cmd + shift + 5 "), ShortcutSpec.parse("cmd+shift+5"))
    }
}
