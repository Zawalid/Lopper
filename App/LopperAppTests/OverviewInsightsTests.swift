import XCTest
import Lopper
@testable import LopperApp

final class OverviewInsightsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(
        _ branch: String, repo: String = "/code/api", minutesAgo: Double = 5, status: UndoStatus = .completed,
        batch: UUID? = nil
    ) -> UndoRecord {
        UndoRecord(
            timestamp: now.addingTimeInterval(-minutesAgo * 60), repoPath: repo, action: .deleteBranch,
            branch: branch, tip: "abc", upstream: nil, worktreePath: nil, trashRef: "refs/lopper/\(branch)",
            status: status, batchID: batch)
    }

    // MARK: Recent activity

    func testRecentActivityGroupsByBatchNewestFirst() {
        let older = UUID(), newer = UUID()
        let history = [
            record("a", minutesAgo: 120, batch: older), record("b", minutesAgo: 119, batch: older),
            record("c", minutesAgo: 10, batch: newer),
        ]
        let activity = OverviewInsights.recentActivity(history: history)

        XCTAssertEqual(activity.map(\.itemCount), [1, 2])
        XCTAssertEqual(activity.map(\.batchID), [newer, older])
    }

    func testRecentActivityIsLimitedAndSkipsPendingAndFailedRecords() {
        var history: [UndoRecord] = (0..<6).map { record("b\($0)", minutesAgo: Double($0 + 1) * 10, batch: UUID()) }
        history.append(record("pending", minutesAgo: 1, status: .pending, batch: UUID()))
        history.append(record("failed", minutesAgo: 1, status: .failed, batch: UUID()))

        let activity = OverviewInsights.recentActivity(history: history, limit: 3)

        XCTAssertEqual(activity.count, 3)
        XCTAssertFalse(activity.contains { $0.itemCount == 0 })
    }

    func testRecentActivityNamesTheRepositoriesOnceAndInOrder() {
        let batch = UUID()
        let history = [
            record("a", repo: "/code/web", batch: batch), record("b", repo: "/code/api", batch: batch),
            record("c", repo: "/code/web", batch: batch),
        ]

        XCTAssertEqual(OverviewInsights.recentActivity(history: history).first?.repoNames, ["api", "web"])
    }

    func testABatchCanBeRestoredOnlyWhileSomethingInItIsStillRemoved() {
        let batch = UUID()
        let restored = OverviewInsights.recentActivity(
            history: [record("a", status: .restored, batch: batch)])
        let removed = OverviewInsights.recentActivity(
            history: [record("a", status: .restored, batch: batch), record("b", batch: batch)])
        let withoutBatch = OverviewInsights.recentActivity(history: [record("a")])

        XCTAssertEqual(restored.first?.canRestore, false)
        XCTAssertEqual(removed.first?.canRestore, true)
        XCTAssertEqual(withoutBatch.first?.canRestore, false)
    }

    // MARK: Lifetime

    func testLifetimeCountsRemovedItemsAndNotRestoredFailedOrPendingOnes() {
        let history = [
            record("a"), record("b", status: .expired), record("c", status: .restored),
            record("d", status: .failed), record("e", status: .pending),
        ]

        XCTAssertEqual(OverviewInsights.lifetimeRemoved(history: history), 2)
    }

    // MARK: Wording

    func testSafeSummaryNamesOnlyWhatThereIs() {
        XCTAssertEqual(
            OverviewInsights.safeSummary(branches: 8, worktrees: 0, repositories: 3),
            "8 branches across 3 repositories are safe to remove")
        XCTAssertEqual(
            OverviewInsights.safeSummary(branches: 5, worktrees: 2, repositories: 1),
            "5 branches and 2 worktrees in 1 repository are safe to remove")
        XCTAssertEqual(
            OverviewInsights.safeSummary(branches: 0, worktrees: 1, repositories: 1),
            "1 worktree in 1 repository is safe to remove")
        XCTAssertEqual(
            OverviewInsights.safeSummary(branches: 1, worktrees: 0, repositories: 2),
            "1 branch across 2 repositories is safe to remove")
    }

    func testFreshnessReadsJustNowThenRelative() {
        XCTAssertEqual(OverviewInsights.freshness(of: now.addingTimeInterval(-20), now: now), "Scanned just now")
        let later = OverviewInsights.freshness(of: now.addingTimeInterval(-600), now: now)
        XCTAssertTrue(later.hasPrefix("Scanned "), later)
        XCTAssertFalse(later.contains("just now"))
    }
}
