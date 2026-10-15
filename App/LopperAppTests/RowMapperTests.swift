import XCTest
import Lopper
@testable import LopperApp

@MainActor
final class RowMapperTests: XCTestCase {
    func testWorktreeRowCarriesItsBranchAndHidesTheBranchRow() {
        let rows = RowMapper.rows(for: Fixtures.sample, sizes: [:])
        let titles = rows.map(\.title)

        XCTAssertEqual(titles.filter { $0 == "feat/in-worktree" }.count, 1, "branch row is folded into the worktree row")
        let worktreeRow = rows.first { $0.kind == .worktree }
        XCTAssertEqual(worktreeRow?.bundledBranch, "feat/in-worktree")
        XCTAssertEqual(worktreeRow?.verdict, .safe)
    }

    func testMainWorktreeGetsNoRowAndOrderingIsSafeFirstOldestFirst() {
        let rows = RowMapper.rows(for: Fixtures.sample, sizes: [:])

        XCTAssertFalse(rows.contains { $0.kind == .worktree && $0.title == "main" })
        let safeTitles = rows.filter { $0.verdict == .safe }.map(\.title)
        // The worktree row is as old as its branch (10 days), so it sorts after fix/old-3 (20 days).
        XCTAssertEqual(safeTitles, ["feat/old-1", "feat/old-2", "fix/old-3", "feat/in-worktree"])
        XCTAssertEqual(rows.last?.verdict, .protected)
    }

    func testProtectedRowsAreNotSelectableAndProduceNoCleanupItem() {
        let rows = RowMapper.rows(for: Fixtures.sample, sizes: [:])
        let main = rows.first { $0.title == "main" }

        XCTAssertEqual(main?.isSelectable, false)
        XCTAssertNil(main?.cleanupItem)
    }

    func testPullRequestLinkIsBuiltFromRemoteAndEvidence() {
        let rows = RowMapper.rows(for: Fixtures.sample, sizes: [:])
        let merged = rows.first { $0.title == "feat/old-1" }

        XCTAssertEqual(merged?.prNumber, 12)
        XCTAssertEqual(merged?.prURL, URL(string: "https://github.com/acme/api/pull/12"))
    }

    func testSizesAreAttachedToWorktreeRows() {
        let path = "/code/wt/feat/in-worktree"
        let rows = RowMapper.rows(for: Fixtures.sample, sizes: [path: DiskUsage(total: 52_000_000, disposable: 0)])

        XCTAssertEqual(rows.first { $0.kind == .worktree }?.size, 52_000_000)
    }
}
