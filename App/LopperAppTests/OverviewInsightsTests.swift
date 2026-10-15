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

    func testActivityCountsAWorktreeAndItsBranchAsOneItem() {
        let batch = UUID()
        let history = [
            UndoRecord(
                timestamp: now, repoPath: "/code/api", action: .removeWorktree, branch: "feat/a", tip: "abc",
                upstream: nil, worktreePath: "/code/wt/a", trashRef: "r1", status: .completed, batchID: batch),
            UndoRecord(
                timestamp: now, repoPath: "/code/api", action: .deleteBranch, branch: "feat/a", tip: "abc",
                upstream: nil, worktreePath: nil, trashRef: "r2", status: .completed, batchID: batch),
        ]

        let activity = OverviewInsights.recentActivity(history: history)

        XCTAssertEqual(activity.first?.itemCount, 1)
        XCTAssertEqual(activity.first?.removedCount, 1)
        XCTAssertEqual(OverviewInsights.lifetimeRemoved(history: history), 1)
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

    // MARK: Worth a look

    private func row(
        _ title: String, repo: String = "api", verdict: VerdictKind = .review, daysAgo: Int? = 10,
        kind: CleanupRow.Kind = .branch, evidence: String = "No merge evidence"
    ) -> CleanupRow {
        CleanupRow(
            id: "\(repo):\(title)", kind: kind, repoRoot: URL(fileURLWithPath: "/code/\(repo)"), repoName: repo,
            title: title, location: "Local branch", path: nil, verdict: verdict, reasons: [], evidence: evidence,
            prNumber: nil, prURL: nil,
            lastCommit: daysAgo.map { now.addingTimeInterval(-Double($0) * 86_400) },
            size: nil, agentHint: nil, extraFiles: [], bundledBranch: nil)
    }

    func testHighlightsAreReviewItemsOnlyOldestFirst() {
        let rows = [
            row("fresh", daysAgo: 1), row("old", daysAgo: 60), row("safe-one", verdict: .safe, daysAgo: 90),
            row("protected-one", verdict: .protected, daysAgo: 99), row("mid", daysAgo: 20),
        ]
        let result = OverviewInsights.reviewHighlights(rows: rows)

        XCTAssertEqual(result.map(\.title), ["old", "mid", "fresh"])
    }

    func testHighlightsAreLimitedAndPutUnknownAgesLast() {
        let rows = [row("unknown", daysAgo: nil), row("a", daysAgo: 5), row("b", daysAgo: 6), row("c", daysAgo: 7)]
        let result = OverviewInsights.reviewHighlights(rows: rows, limit: 3)

        XCTAssertEqual(result.map(\.title), ["c", "b", "a"])
        XCTAssertEqual(OverviewInsights.reviewHighlights(rows: rows, limit: 4).last?.title, "unknown")
    }

    func testHighlightsCarryWhatTheListNeedsToOpenTheItem() {
        let result = OverviewInsights.reviewHighlights(
            rows: [row("fix/x", repo: "web", kind: .worktree, evidence: "Not merged")])

        XCTAssertEqual(result.first?.repoID, "/code/web")
        XCTAssertEqual(result.first?.repoName, "web")
        XCTAssertEqual(result.first?.evidence, "Not merged")
        XCTAssertEqual(result.first?.kind, .worktree)
    }

    // MARK: Stale work

    func testStaleInsightCountsUntouchedItemsPastTheThresholdOnly() {
        let rows = [
            row("old-review", daysAgo: 45), row("old-safe", verdict: .safe, daysAgo: 90),
            row("recent", daysAgo: 3), row("old-protected", verdict: .protected, daysAgo: 400),
            row("unknown", daysAgo: nil),
        ]
        let insight = OverviewInsights.staleInsight(rows: rows, staleDays: 30, now: now)

        XCTAssertEqual(insight, StaleInsight(count: 2, days: 30))
    }

    func testNoStaleInsightWhenNothingIsOld() {
        XCTAssertNil(OverviewInsights.staleInsight(rows: [row("new", daysAgo: 2)], staleDays: 30, now: now))
        XCTAssertNil(OverviewInsights.staleInsight(rows: [], staleDays: 30, now: now))
    }

    func testStaleInsightSentence() {
        XCTAssertEqual(
            StaleInsight(count: 4, days: 30).sentence, "4 items haven't been touched in 30+ days")
        XCTAssertEqual(
            StaleInsight(count: 1, days: 14).sentence, "1 item hasn't been touched in 14+ days")
    }

    // MARK: Scanning placeholders

    func testSkeletonCountIsWhatIsLeftToScanWithinTheLimit() {
        XCTAssertEqual(OverviewInsights.skeletonCount(done: 3, total: 17, limit: 6), 6)
        XCTAssertEqual(OverviewInsights.skeletonCount(done: 15, total: 17, limit: 6), 2)
        XCTAssertEqual(OverviewInsights.skeletonCount(done: 17, total: 17, limit: 6), 0)
        XCTAssertEqual(OverviewInsights.skeletonCount(done: 0, total: 0, limit: 6), 0)
        XCTAssertEqual(OverviewInsights.skeletonCount(done: 20, total: 17, limit: 6), 0)
    }

    // MARK: Just removed

    func testJustRemovedMentionsACleanupFromTheLastTenMinutes() {
        let batch = UUID()
        let history = [record("a", minutesAgo: 3, batch: batch), record("b", minutesAgo: 3, batch: batch)]

        XCTAssertEqual(OverviewInsights.justRemoved(history: history, now: now), "Just removed 2 items")
    }

    func testJustRemovedIsSilentForOldOrRestoredCleanups() {
        let old = [record("a", minutesAgo: 40, batch: UUID())]
        let restored = [record("a", minutesAgo: 2, status: .restored, batch: UUID())]

        XCTAssertNil(OverviewInsights.justRemoved(history: old, now: now))
        XCTAssertNil(OverviewInsights.justRemoved(history: restored, now: now))
        XCTAssertNil(OverviewInsights.justRemoved(history: [], now: now))
    }
}
