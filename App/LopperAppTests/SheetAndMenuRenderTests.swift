import XCTest
import SwiftUI
import Lopper
@testable import LopperApp

@MainActor
final class SheetAndMenuRenderTests: XCTestCase {
    func testCleanReviewRowsRender() async throws {
        let model = await RenderSupport.makeModel(snapshots: [Fixtures.sample])
        model.beginCleanAllSafe()
        let rows = model.clean?.rows ?? []
        XCTAssertEqual(rows.count, 4)

        // The sheet's List cannot be drawn offscreen, so its rows are laid out in a plain stack.
        try RenderSupport.render(
            "clean-rows", size: CGSize(width: 560, height: 300),
            VStack(spacing: 10) { ForEach(rows) { ReviewRow(row: $0, isIncluded: true) } }
                .padding(16)
                .environment(model))
    }

    func testNotRemovedRowsRenderWithReasonsFilesAndActions() async throws {
        let snapshot = Fixtures.snapshot(
            branches: [Fixtures.branch("main", .protected)],
            worktrees: [Fixtures.worktree("notes-wt", .review, extraFiles: ["notes.md"]), Fixtures.worktree("locked-wt", .review)])
        let model = await RenderSupport.makeModel(snapshots: [snapshot])
        let dirty = try XCTUnwrap(model.allRows.first { $0.title == "notes-wt" })
        let locked = try XCTUnwrap(model.allRows.first { $0.title == "locked-wt" })
        let changes = WorktreeChanges(
            files: [
                WorktreeChange(path: "src/App.swift", kind: .modified),
                WorktreeChange(path: "notes/ideas.md", kind: .untracked),
                WorktreeChange(path: "old/legacy-file-with-a-rather-long-name-that-needs-truncating.txt", kind: .deleted),
                WorktreeChange(path: "docs/plan.md", kind: .added),
                WorktreeChange(path: "scratch.txt", kind: .untracked),
            ],
            total: 9)
        let refusal = "git couldn't complete this step: '/code/wt/notes-wt' contains modified or untracked files, use --force to delete it"

        try RenderSupport.render(
            "not-removed", size: CGSize(width: 560, height: 520),
            VStack(alignment: .leading, spacing: 18) {
                NotRemovedRow(
                    outcome: ItemOutcome(id: "a", title: dirty.title, status: .failed, message: refusal),
                    row: dirty, changes: changes, isWorking: false)
                Divider()
                NotRemovedRow(
                    outcome: ItemOutcome(id: "b", title: locked.title, status: .skipped, message: "The worktree is locked"),
                    row: locked, changes: nil, isWorking: false)
            }
            .padding(16)
            .environment(model))
    }

    func testMenuBarShowsFinishedAgentsLine() throws {
        let m = Fixtures.agentMeasurements
        let model = AppModel.preview(
            snapshots: [Fixtures.agentSample], sizes: m.sizes, activity: m.activity,
            clock: { Fixtures.now })
        XCTAssertEqual(MenuBarView.agentsLine(for: model.agentsSummary), "2 agent worktrees finished")
        XCTAssertNil(MenuBarView.agentsLine(for: AgentsSummary()))
        try RenderSupport.render(
            "menubar-agents", size: CGSize(width: 320, height: 420), MenuBarView().environment(model))
    }

    func testMenuBarPopoverRenders() async throws {
        let model = await RenderSupport.makeModel(snapshots: [Fixtures.sample])
        try RenderSupport.render("menubar", size: CGSize(width: 320, height: 420),
                                 MenuBarView().environment(model))
    }
}
