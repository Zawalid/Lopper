import XCTest
import SwiftUI
import Lopper
@testable import LopperApp

@MainActor
final class InspectorRenderTests: XCTestCase {
    func testInspectorRendersASafeWorktree() async throws {
        let model = await RenderSupport.makeModel(snapshots: [Fixtures.sample])
        model.focusedRowID = "worktree:/code/wt/feat/in-worktree"
        XCTAssertNotNil(model.focusedRow)

        try RenderSupport.render("inspector", size: CGSize(width: 320, height: 520),
                                 InspectorContent().environment(model))
    }

    func testInspectorRendersAReviewBranchWithItsReasons() async throws {
        let model = await RenderSupport.makeModel(snapshots: [Fixtures.sample])
        model.focusedRowID = "branch:/code/api#wip/unmerged"
        XCTAssertEqual(model.focusedRow?.verdict, .review)

        try RenderSupport.render("inspector-review", size: CGSize(width: 320, height: 420),
                                 InspectorContent().environment(model))
    }
}
