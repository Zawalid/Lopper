import XCTest
import Lopper
@testable import LopperApp

@MainActor
final class AgentsModelTests: XCTestCase {
    private func measuredModel() -> AppModel {
        let m = Fixtures.agentMeasurements
        return AppModel.preview(
            snapshots: [Fixtures.agentSample], sizes: m.sizes, activity: m.activity,
            route: .overview, clock: { Fixtures.now })
    }

    private func titles(_ rows: [AgentRow]) -> [String] { rows.map(\.title).sorted() }

    func testEveryStateIsCountedFromTheSample() {
        let summary = measuredModel().agentsSummary
        XCTAssertEqual(summary.total, 9)
        XCTAssertEqual(summary.reclaimable, 2)
        XCTAssertEqual(summary.abandonedReclaimable, 2)
        XCTAssertEqual(summary.notMerged, 4)
        XCTAssertEqual(summary.folderOnly, 1)
        XCTAssertEqual(summary.active, 1)
        XCTAssertEqual(summary.protected, 1)
        XCTAssertEqual(summary.measuring, 0)
        XCTAssertGreaterThan(summary.reclaimableBytes, 0)
    }

    func testReclaimFinishedContainsOnlyReclaimableRows() {
        let model = measuredModel()
        model.beginReclaimFinishedAgents()

        let rows = model.clean?.rows ?? []
        XCTAssertEqual(rows.map(\.title).sorted(), ["claude/finished-a", "claude/finished-b"])
        XCTAssertTrue(rows.allSatisfy { $0.verdict == .safe })
    }

    func testLockedFinishedRowAndUnmergedRowsAreNeverInTheBulkSet() {
        let model = measuredModel()
        let bulk = model.reclaimableAgentRows
        XCTAssertFalse(bulk.contains { $0.title.contains("locked-done") })
        XCTAssertFalse(bulk.contains { $0.assessment.state == .unmerged || $0.assessment.state == .abandoned })
        XCTAssertFalse(bulk.contains { $0.assessment.state == .active })
    }

    func testUnmeasuredRowsAreNotReclaimable() {
        let model = AppModel.preview(
            snapshots: [Fixtures.agentSample], sizes: [:], activity: [:], clock: { Fixtures.now })
        XCTAssertEqual(model.reclaimableAgentRows.count, 0)
        XCTAssertGreaterThan(model.agentsSummary.measuring, 0)
    }

    func testExcludingARowRemovesItFromTheReclaim() {
        let model = measuredModel()
        let first = model.reclaimableAgentRows[0].id
        model.setAgentIncluded(first, false)
        XCTAssertEqual(model.reclaimableAgentRows.count, 1)
        model.setAgentIncluded(first, true)
        XCTAssertEqual(model.reclaimableAgentRows.count, 2)
    }

    func testAbandonedBulkKeepsBranchesAndIsReviewVerdict() {
        let model = measuredModel()
        model.beginReclaimAbandonedAgents()
        let rows = model.clean?.rows ?? []
        XCTAssertEqual(rows.map(\.title).sorted(), ["claude/old-feature", "old-detached"])
        XCTAssertTrue(rows.allSatisfy { $0.verdict == .review })
        for row in rows {
            guard case .worktree(_, _, let approved, let deleteBranch)? = row.cleanupItem else {
                return XCTFail("expected a worktree item")
            }
            XCTAssertEqual(approved, .review)
            XCTAssertNil(deleteBranch, "an unmerged worktree's branch must be kept")
        }
    }

    func testReviewOpensOneRowAndRefusesBlockedOnes() {
        let model = measuredModel()
        let committed = model.agentRows.first { $0.title == "claude/wip" }!
        model.beginReview(row: committed.row)
        XCTAssertEqual(model.clean?.rows.map(\.title), ["claude/wip"])
        model.clean = nil

        let scratch = model.agentRows.first { $0.title == "claude/scratch" }!
        model.beginReview(row: scratch.row)
        XCTAssertNil(model.clean, "uncommitted work must not reach the sheet")

        let active = model.agentRows.first { $0.title == "claude/just-now" }!
        model.beginReview(row: active.row)
        XCTAssertNil(model.clean)
    }

    func testFiltersToolAndSearch() {
        let model = measuredModel()
        model.agentFilter = .notMerged
        XCTAssertEqual(titles(model.visibleAgentRows), ["claude/scratch", "claude/wip"])
        model.agentFilter = .abandoned
        XCTAssertEqual(titles(model.visibleAgentRows), ["claude/old-feature", "old-detached"])
        model.agentFilter = .all
        model.agentToolFilter = .cursor
        XCTAssertTrue(model.visibleAgentRows.isEmpty)
        model.agentToolFilter = nil
        model.agentSearchText = "FINISHED-A"
        XCTAssertEqual(titles(model.visibleAgentRows), ["claude/finished-a"])
    }

    func testRowsAreOrderedLoudestFirst() {
        let order = measuredModel().agentRows.map(\.assessment.state)
        XCTAssertEqual(order, order.sorted { $0.displayRank < $1.displayRank })
        XCTAssertEqual(order.first, .unmerged)
        XCTAssertEqual(order.last, .protected)
    }

    func testPageStates() {
        let none = AppModel.preview(snapshots: [Fixtures.sample], clock: { Fixtures.now })
        XCTAssertEqual(none.agentsPageState, .noAgents(repositories: 1))

        let ready = measuredModel()
        XCTAssertEqual(ready.agentsPageState, .ready)

        let noFolders = AppModel.preview(snapshots: [], roots: [])
        XCTAssertEqual(noFolders.agentsPageState, .needsFolders)

        let scanning = AppModel.preview(snapshots: [], phase: .scanning(done: 0, total: 3))
        XCTAssertEqual(scanning.agentsPageState, .scanning)
    }

    func testNothingToReclaimWhenOnlyUnmergedWorkExists() {
        let wip = Fixtures.snapshot(
            branches: [Fixtures.branch("main", .protected)],
            worktrees: [Fixtures.agentWorktree("wip", kind: .review, evidence: .none, ahead: 2, daysAgo: 4)])
        let model = AppModel.preview(
            snapshots: [wip],
            sizes: ["/code/api/.claude/worktrees/wip": 10_000_000],
            activity: ["/code/api/.claude/worktrees/wip": Fixtures.now.addingTimeInterval(-4 * 86_400)],
            clock: { Fixtures.now })
        XCTAssertEqual(model.agentsPageState, .nothingToReclaim)
    }

    func testGraceComesFromSettings() {
        let model = measuredModel()
        // The "just-now" worktree is about 7 minutes old: with a zero grace it is no longer active.
        model.updateSettings { $0.agentFinishedGraceMinutes = 0 }
        let row = model.agentRows.first { $0.title == "claude/just-now" }
        XCTAssertEqual(row?.assessment.state, .finished)
    }
}
