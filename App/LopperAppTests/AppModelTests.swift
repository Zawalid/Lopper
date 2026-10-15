import XCTest
import Lopper
@testable import LopperApp

@MainActor
final class AppModelTests: XCTestCase {
    private func makeModel(
        _ snapshots: [RepoSnapshot], failures: [URL] = [], sizes: [String: Int64] = [:]
    ) -> (AppModel, FakeEngineClient) {
        let client = FakeEngineClient(snapshots: snapshots)
        client.failures = failures
        client.sizeByPath = sizes
        let store = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-test-settings-\(UUID().uuidString).json"))
        let model = AppModel(
            client: client, store: store,
            settings: Settings(roots: [URL(fileURLWithPath: "/code")]))
        return (model, client)
    }

    private func settle(_ model: AppModel) async {
        for _ in 0..<200 {
            if case .ready = model.phase, model.sizes.count >= 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(30))
    }

    func testScanPopulatesSummariesAndTotals() async {
        let (model, _) = makeModel([Fixtures.sample], sizes: ["/code/wt/feat/in-worktree": 52_000_000])
        model.startScan()
        await settle(model)

        XCTAssertEqual(model.summaries.count, 1)
        let totals = model.totals
        XCTAssertEqual(totals.safeBranches, 3)
        XCTAssertEqual(totals.safeWorktrees, 1)
        XCTAssertEqual(totals.review, 1)
        XCTAssertEqual(totals.protected, 1)
        XCTAssertEqual(totals.reclaimableBytes, 52_000_000)
        XCTAssertNotNil(model.lastScan)
    }

    func testFailedRepositoryIsReportedWithoutHidingTheOthers() async {
        let broken = URL(fileURLWithPath: "/code/broken")
        let (model, _) = makeModel([Fixtures.sample], failures: [broken])
        model.startScan()
        await settle(model)

        XCTAssertEqual(model.summaries.count, 2)
        XCTAssertEqual(model.summaries.first { $0.root == broken }?.failure, "boom")
        XCTAssertEqual(model.totals.safeBranches, 3)
    }

    func testFiltersAndSearchNarrowTheVisibleRows() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        let repoID = Fixtures.root.path

        XCTAssertEqual(model.visibleRows(forRepo: repoID).count, 6)
        model.verdictFilter = .safe
        XCTAssertEqual(model.visibleRows(forRepo: repoID).count, 4)
        model.kindFilter = .worktrees
        XCTAssertEqual(model.visibleRows(forRepo: repoID).map(\.title), ["feat/in-worktree"])
        model.kindFilter = .all
        model.searchText = "OLD-2"
        XCTAssertEqual(model.visibleRows(forRepo: repoID).map(\.title), ["feat/old-2"])
    }

    func testCleanAllSafeSendsOnlySafeItemsAndOffersUndo() async {
        let (model, client) = makeModel([Fixtures.sample], sizes: ["/code/wt/feat/in-worktree": 52_000_000])
        model.startScan()
        await settle(model)

        model.beginCleanAllSafe()
        XCTAssertEqual(model.clean?.includedRows.count, 4)
        model.runClean()
        for _ in 0..<200 where model.clean?.phase != .finished {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(client.cleanedItems.count, 4)
        XCTAssertTrue(client.cleanedItems.allSatisfy { item in
            switch item {
            case .branch(_, _, let approved), .worktree(_, _, let approved, _): approved == .safe
            }
        })
        XCTAssertEqual(model.clean?.removedCount, 4)
        XCTAssertEqual(model.clean?.reclaimedBytes, 52_000_000)
        XCTAssertEqual(model.toast?.removed, 4)
    }

    func testExcludedRowsAreNotCleaned() async {
        let (model, client) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)

        model.beginCleanAllSafe()
        model.setExcluded("branch:/code/api#feat/old-1", true)
        model.runClean()
        for _ in 0..<200 where model.clean?.phase != .finished {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(client.cleanedItems.count, 3)
        XCTAssertFalse(client.cleanedItems.contains { $0.id == "branch:/code/api#feat/old-1" })
    }

    func testSkippedItemsAreReportedAndDoNotCountAsReclaimed() async {
        let (model, client) = makeModel([Fixtures.sample])
        client.cleanOutcome = { item in
            item.id.contains("old-2") ? .skipped(reason: "Verdict changed since it was approved") : .removed(
                UndoRecord(timestamp: Fixtures.now, repoPath: "/code/api", action: .deleteBranch, branch: "x",
                           tip: "abc", upstream: nil, worktreePath: nil, trashRef: "r", status: .completed))
        }
        model.startScan()
        await settle(model)

        model.beginCleanAllSafe()
        model.runClean()
        for _ in 0..<200 where model.clean?.phase != .finished {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.clean?.removedCount, 3)
        XCTAssertEqual(model.clean?.problemCount, 1)
        XCTAssertEqual(model.clean?.outcomes.first { $0.status == .skipped }?.title, "feat/old-2")
    }

    func testUndoToastRestoresItsBatch() async {
        let (model, client) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        model.beginCleanAllSafe()
        model.runClean()
        for _ in 0..<200 where model.clean?.phase != .finished {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let batch = model.toast?.id

        model.undoToast()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertNotNil(batch)
        XCTAssertEqual(client.restoredBatches, [batch].compactMap { $0 })
        XCTAssertNil(model.toast)
    }

    func testProtectedRowsCanNeverBeChecked() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        let main = model.allRows.first { $0.title == "main" }!

        model.checked = [main.id]

        XCTAssertTrue(model.checkedRows.isEmpty)
    }

    func testAddingAThrowawayNameIsRememberedAndTriggersARescan() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)

        model.addThrowaway(name: ".env.test", repoRoot: Fixtures.root)

        XCTAssertTrue(model.settings.disposableSet(for: Fixtures.root).contains(".env.test"))
        XCTAssertTrue(model.isScanning)
    }
}
