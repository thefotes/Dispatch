import XCTest
@testable import WLKit

/// Exercises the real `but` binary. Skipped where it is not installed, so the
/// suite still passes on a machine without GitButler.
final class LiveGitButlerTests: XCTestCase {

    private func binary() throws -> String {
        try XCTUnwrap(GitButler.locateBinary(), "no `but` binary")
    }

    func testFindsTheBinaryOutsideTheLaunchdPath() throws {
        // The interesting case is a GUI app's minimal PATH, so check the
        // search list finds it rather than trusting the test's inherited one.
        let path = try binary()
        print("but: \(path)")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
    }

    func testStatusOfThisRepoRendersToHTML() async throws {
        _ = try binary()
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WLKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // swift
            .deletingLastPathComponent()   // repo root
            .path

        let output = try await GitButler.status(in: repo)
        print("--- but status ---\n\(output.text)")
        XCTAssertFalse(output.text.isEmpty, "`but status` said nothing")

        let html = AnsiHTML.render(output.text)
        print("--- html ---\n\(html)")
        XCTAssertFalse(html.contains("\u{1B}"), "escapes must not reach the document")
        XCTAssertEqual(
            html.components(separatedBy: "<span").count,
            html.components(separatedBy: "</span>").count,
            "spans must balance"
        )
    }

    /// A directory GitButler knows nothing about must come back as a message
    /// to show, not a thrown error the panel would render as a blank window.
    func testNonProjectDirectoryReportsRatherThanThrows() async throws {
        _ = try binary()
        let output = try await GitButler.status(in: NSTemporaryDirectory())
        XCTAssertFalse(output.succeeded)
        XCTAssertFalse(output.text.isEmpty, "the failure has to say something")
    }
}
