import XCTest
@testable import WLKit

final class GitButlerLandPlanTests: XCTestCase {

    private func json(stacks: [[[String: String]]]) throws -> Data {
        let object: [String: Any] = [
            "stacks": stacks.map { branches in
                ["branches": branches]
            },
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Status lists branches top first; landing must go bottom up.
    func testBottomBranchLandsFirst() throws {
        let data = try json(stacks: [[
            ["name": "top", "branchStatus": "completelyUnpushed"],
            ["name": "bottom", "branchStatus": "completelyUnpushed"],
        ]])
        XCTAssertEqual(try GitButler.parseLandPlan(data), ["bottom", "top"])
    }

    func testIntegratedBranchesAreSkipped() throws {
        let data = try json(stacks: [[
            ["name": "top", "branchStatus": "unpushedCommits"],
            ["name": "landed", "branchStatus": "integrated"],
        ]])
        XCTAssertEqual(try GitButler.parseLandPlan(data), ["top"])
    }

    func testEachStackGoesBottomUp() throws {
        let data = try json(stacks: [
            [
                ["name": "a-top", "branchStatus": "completelyUnpushed"],
                ["name": "a-bottom", "branchStatus": "completelyUnpushed"],
            ],
            [["name": "b", "branchStatus": "completelyUnpushed"]],
        ])
        XCTAssertEqual(try GitButler.parseLandPlan(data), ["a-bottom", "a-top", "b"])
    }

    func testEmptyWorkspaceMeansEmptyPlan() throws {
        let data = try JSONSerialization.data(withJSONObject: ["stacks": []])
        XCTAssertEqual(try GitButler.parseLandPlan(data), [])
    }

    /// An error message where JSON should be must throw, not land nothing —
    /// the caller tells "nothing to land" and "could not tell" apart.
    func testNonJSONOutputThrows() {
        XCTAssertThrowsError(try GitButler.parseLandPlan(Data("not a workspace\n".utf8)))
        XCTAssertThrowsError(try GitButler.parseLandPlan(Data("{\"ok\":1}".utf8)))
    }
}
