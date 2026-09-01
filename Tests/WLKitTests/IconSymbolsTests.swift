import XCTest
import AppKit
@testable import WLKit

/// Guards the menu-bar glyph against a failure that is invisible until it is
/// embarrassing: `NSImage(systemSymbolName:)` returns nil for a name the running
/// system does not have, the drawing code falls back to an empty image, and the
/// icon becomes a bare status dot with no keyboard at all.
///
/// Worse, the states that need the glyph most are the error ones, so the icon
/// vanishes precisely when someone is trying to work out what is wrong.
final class IconSymbolsTests: XCTestCase {

    func testEverySymbolTheIconDrawsExistsOnThisSystem() {
        for name in IconSymbols.all {
            XCTAssertNotNil(
                NSImage(systemSymbolName: name, accessibilityDescription: nil),
                "\(name) is not an SF Symbol on this system, so the icon would draw blank"
            )
        }
    }

    /// The glyph is how the icon is found in a crowded menu bar, so every state
    /// keeps the keyboard rather than swapping to a generic warning mark.
    func testEveryStateKeepsTheKeyboardShape() {
        for name in IconSymbols.all {
            XCTAssertTrue(name.hasPrefix("keyboard"), "\(name) would not read as this app")
        }
    }
}
