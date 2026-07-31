import XCTest
@testable import WLKit

/// The sample is a real `but status` line, escapes and box characters and all,
/// since the point of this renderer is that output and not ANSI in general.
final class AnsiHTMLTests: XCTestCase {

    func testPlainTextPassesThroughUntouched() {
        XCTAssertEqual(AnsiHTML.render("╭┄ zz [uncommitted]"), "╭┄ zz [uncommitted]")
    }

    func testHTMLIsEscaped() {
        XCTAssertEqual(AnsiHTML.render("a<b & c>d"), "a&lt;b &amp; c&gt;d")
    }

    func testBasicColoursBecomeSpans() {
        let html = AnsiHTML.render("\u{1B}[36muncommitted\u{1B}[0m")
        XCTAssertEqual(html, "<span style=\"color:\(AnsiHTML.palette[6])\">uncommitted</span>")
    }

    func testBoldAndColourCombine() {
        let html = AnsiHTML.render("\u{1B}[1;34mzz\u{1B}[0m")
        XCTAssertTrue(html.contains("class=\"b\""), html)
        XCTAssertTrue(html.contains(AnsiHTML.palette[4]), html)
    }

    func testResetClosesTheSpan() {
        let html = AnsiHTML.render("\u{1B}[2mdim\u{1B}[0m plain")
        XCTAssertEqual(html, "<span class=\"d\">dim</span> plain")
    }

    func testUnterminatedStyleIsStillClosed() {
        let html = AnsiHTML.render("\u{1B}[31mred")
        XCTAssertTrue(html.hasSuffix("</span>"), html)
    }

    func testBrightColoursUseTheUpperPalette() {
        let html = AnsiHTML.render("\u{1B}[92mbright\u{1B}[0m")
        XCTAssertTrue(html.contains(AnsiHTML.palette[10]), html)
    }

    func testTruecolourAndIndexedColour() {
        XCTAssertTrue(AnsiHTML.render("\u{1B}[38;2;18;52;86mx").contains("#123456"))
        XCTAssertEqual(AnsiHTML.xterm256(232), "#080808")
        XCTAssertEqual(AnsiHTML.xterm256(196), "#FF0000")
    }

    /// A cursor-hide left in the output must not appear as literal text.
    func testNonSGREscapesAreDroppedRatherThanPrinted() {
        XCTAssertEqual(AnsiHTML.render("\u{1B}[?25lhi\u{1B}[2K"), "hi")
    }

    /// A window title would otherwise land in the middle of the stack.
    func testOSCStringsAreConsumedWhole() {
        XCTAssertEqual(AnsiHTML.render("\u{1B}]0;title\u{7}after"), "after")
        XCTAssertEqual(AnsiHTML.render("\u{1B}]0;title\u{1B}\\after"), "after")
        XCTAssertEqual(AnsiHTML.render("before\u{1B}]0;unterminated"), "before")
    }

    func testRealStatusLineRoundTrips() {
        let line = "\u{1B}[32m●\u{1B}[0m   \u{1B}[35mk\u{1B}[0m\u{1B}[2mrz\u{1B}[0m cli: adapt"
        let html = AnsiHTML.render(line)
        XCTAssertFalse(html.contains("\u{1B}"), "no escape may survive")
        XCTAssertTrue(html.contains("cli: adapt"))
        XCTAssertEqual(
            html.components(separatedBy: "<span").count - 1,
            html.components(separatedBy: "</span>").count - 1,
            "spans must balance"
        )
    }
}
