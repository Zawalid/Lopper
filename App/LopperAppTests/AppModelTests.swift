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

    /// Waits for the scan to finish and, when `sizes` is given, for that many worktree sizes to arrive.
    private func settle(_ model: AppModel, sizes: Int = 0) async {
        for _ in 0..<300 {
            if case .ready = model.phase, model.sizes.count >= sizes { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testScanPopulatesSummariesAndTotals() async {
        let (model, _) = makeModel([Fixtures.sample], sizes: ["/code/wt/feat/in-worktree": 52_000_000])
        model.startScan()
        await settle(model, sizes: 1)

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
        await settle(model, sizes: 1)

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

    // MARK: Review fixes

    func testStopMidBatchStillFinishesKeepsUndoAndCountsOnlyWhatWasRemoved() async {
        let (model, client) = makeModel([Fixtures.sample])
        client.cleanItemDelay = .milliseconds(80)
        model.startScan()
        await settle(model)
        model.beginCleanAllSafe()
        model.runClean()
        await waitUntil { (model.clean?.outcomes.count ?? 0) >= 1 }

        model.cancelClean()

        XCTAssertEqual(model.clean?.isStopping, true)
        await waitUntil { model.clean?.phase == .finished }
        XCTAssertEqual(model.clean?.phase, .finished, "a stopped batch must still finish")
        let removed = model.clean?.removedCount ?? 0
        XCTAssertGreaterThanOrEqual(removed, 1)
        XCTAssertLessThan(removed, 4)
        XCTAssertEqual(model.toast?.removed, removed, "what was removed must stay undoable")
    }

    func testStartingACleanWhileAScanIsRunningDoesNotLeaveTheScanSpinnerStuck() async {
        let (model, client) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        client.scanDelay = .seconds(5)
        model.startScan()
        XCTAssertTrue(model.isScanning)

        model.beginCleanAllSafe()
        model.runClean()
        await waitUntil { model.clean?.phase == .finished }

        XCTAssertEqual(model.clean?.phase, .finished)
        XCTAssertFalse(model.isScanning, "the cancelled scan must not leave the app in a scanning state")
    }

    func testDismissingAFinishedSheetBehavesLikeDone() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        model.beginCleanAllSafe()
        model.runClean()
        await waitUntil { model.clean?.phase == .finished }

        model.dismissClean()

        XCTAssertNil(model.clean)
        XCTAssertTrue(model.isScanning, "closing the finished sheet must rescan so removed items disappear")
    }

    func testBeginningACleanIsIgnoredWhileASheetIsAlreadyOpen() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        model.beginCleanAllSafe()
        let first = model.clean
        model.setExcluded(first!.rows[0].id, true)

        model.beginCleanAllSafe()

        XCTAssertTrue(model.clean?.excluded.contains(first!.rows[0].id) == true)
    }

    func testOverviewStateDistinguishesTheEmptyCases() async {
        let store = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-test-settings-\(UUID().uuidString).json"))
        let noFolders = AppModel(client: FakeEngineClient(snapshots: []), store: store, settings: Settings())
        XCTAssertEqual(noFolders.overviewState, .needsFolders)

        let (empty, _) = makeModel([])
        empty.startScan()
        await settle(empty)
        XCTAssertEqual(empty.overviewState, .nothingFound)

        let tidyOnly = Fixtures.snapshot(branches: [Fixtures.branch("main", .protected)])
        let (tidy, _) = makeModel([tidyOnly])
        tidy.startScan()
        await settle(tidy)
        XCTAssertEqual(tidy.overviewState, .allTidy(review: 0))

        let (ready, _) = makeModel([Fixtures.sample])
        ready.startScan()
        await settle(ready)
        XCTAssertEqual(ready.overviewState, .ready)
    }

    func testFailedRestoreShowsANoticeInsteadOfStayingSilent() async {
        let (model, client) = makeModel([Fixtures.sample])
        client.restoreBatchOutcomes = [.failed(message: "Can't restore this: /code/wt/x already exists.")]
        model.startScan()
        await settle(model)
        model.beginCleanAllSafe()
        model.runClean()
        await waitUntil { model.clean?.phase == .finished }

        model.undoToast()
        await waitUntil { model.notice != nil }

        XCTAssertTrue(model.notice?.contains("Couldn't restore 1 item") == true, model.notice ?? "nil")
        XCTAssertTrue(model.notice?.contains("already exists") == true)
        model.dismissNotice()
        XCTAssertNil(model.notice)
    }

    func testHeroShowsAnItemCountWhenOnlyBranchesAreSafe() async {
        let branchesOnly = Fixtures.snapshot(branches: [
            Fixtures.branch("main", .protected), Fixtures.branch("feat/a", .safe), Fixtures.branch("feat/b", .safe),
        ])
        let (model, _) = makeModel([branchesOnly])
        model.startScan()
        await settle(model)

        XCTAssertEqual(model.heroHeadline, "Ready to clean")
        XCTAssertEqual(model.heroValue, "2 items")

        let (sized, _) = makeModel([Fixtures.sample], sizes: ["/code/wt/feat/in-worktree": 52_000_000])
        sized.startScan()
        await settle(sized, sizes: 1)
        XCTAssertEqual(sized.heroHeadline, "Ready to reclaim")
        XCTAssertTrue(sized.heroValue.contains("MB"), sized.heroValue)
    }

    // MARK: Folders

    func testAddingFoldersMergesWithoutDuplicatesAndRescans() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)

        model.addRoots([URL(fileURLWithPath: "/code"), URL(fileURLWithPath: "/work/projects")])

        XCTAssertEqual(model.settings.roots.map(\.path).sorted(), ["/code", "/work/projects"])
        XCTAssertTrue(model.isScanning, "adding a folder must rescan so its repositories appear")
    }

    func testRemovingAFolderRescansAndRemovingTheLastOneReturnsToOnboarding() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.addRoots([URL(fileURLWithPath: "/work/projects")])
        await settle(model)
        XCTAssertEqual(model.settings.roots.count, 2)

        model.removeRoot(URL(fileURLWithPath: "/work/projects"))
        XCTAssertEqual(model.settings.roots.map(\.path), ["/code"])

        model.removeRoot(URL(fileURLWithPath: "/code"))
        XCTAssertTrue(model.settings.roots.isEmpty)
        XCTAssertEqual(model.overviewState, .needsFolders)
        XCTAssertTrue(model.results.isEmpty, "nothing from the removed folders may stay listed")
        XCTAssertFalse(model.isScanning)
    }

    func testFolderSummaryNamesTheFoldersBeingScanned() {
        let (model, _) = makeModel([])
        XCTAssertEqual(model.foldersSummary, "Looking in /code")
        model.addRoots([URL(fileURLWithPath: "/work/projects")])
        XCTAssertEqual(model.foldersSummary, "Looking in /code and 1 more folder")
    }

    func testRepositoriesThatNeedAttentionComeFirstAndTidyOnesAreSeparate() async {
        func repo(_ name: String, _ branches: [(String, VerdictKind)]) -> RepoSnapshot {
            let root = URL(fileURLWithPath: "/code/\(name)")
            return Fixtures.snapshot(
                name: name, root: root,
                branches: [Fixtures.branch("main", .protected, root: root)]
                    + branches.map { Fixtures.branch($0.0, $0.1, root: root) })
        }
        let (model, _) = makeModel([
            repo("alpha", []),
            repo("zeta", [("a", .safe), ("b", .safe)]),
            repo("mid", [("c", .review)]),
            repo("beta", []),
        ])
        model.startScan()
        await settle(model)

        XCTAssertEqual(model.attentionSummaries.map(\.name), ["zeta", "mid"])
        XCTAssertEqual(model.tidySummaries.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(model.orderedSummaries.map(\.name), ["zeta", "mid", "alpha", "beta"])
    }

    // MARK: Settings

    func testACorruptSettingsFileProducesANoticeNamingTheBackup() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-model-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: file)

        let model = AppModel(client: FakeEngineClient(snapshots: []), store: SettingsStore(url: file))

        XCTAssertEqual(model.settings, Settings())
        let notice = try XCTUnwrap(model.notice)
        XCTAssertTrue(notice.contains("settings.json.broken-"), notice)
    }

    func testOnlySettingsThatChangeWhatIsFoundTriggerARescan() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)

        model.updateSettings { $0.trashRetentionDays = 7 }
        XCTAssertFalse(model.isScanning, "retention does not change what is found")

        model.updateSettings { $0.staleDays = 90 }
        XCTAssertFalse(model.isScanning)

        model.updateSettings { $0.scanDepth = 6 }
        XCTAssertTrue(model.isScanning, "depth changes what is found")
    }

    func testAnUnchangedSettingIsNotWrittenOrRescanned() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)

        model.updateSettings { $0.scanDepth = model.settings.scanDepth }

        XCTAssertFalse(model.isScanning)
    }

    func testIgnoringARepositoryRescansAndTheRepositoryDisappears() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)

        model.updateSettings { $0.repos[Fixtures.root.path, default: RepoOverrides()].isIgnored = true }

        XCTAssertTrue(model.isScanning)
    }

    // MARK: Settings window support

    func testRepositoryCountIsPerFolderIncludingNestedRepositories() async {
        func repo(_ path: String) -> RepoSnapshot {
            let root = URL(fileURLWithPath: path)
            return Fixtures.snapshot(
                name: root.lastPathComponent, root: root,
                branches: [Fixtures.branch("main", .protected, root: root)])
        }
        let (model, _) = makeModel([repo("/code/a"), repo("/code/group/b"), repo("/elsewhere/c")])
        model.startScan()
        await settle(model)

        XCTAssertEqual(model.repositoryCount(inFolder: URL(fileURLWithPath: "/code")), 2)
        XCTAssertEqual(model.repositoryCount(inFolder: URL(fileURLWithPath: "/elsewhere")), 1)
        XCTAssertEqual(model.repositoryCount(inFolder: URL(fileURLWithPath: "/cod")), 0, "a path prefix is not a parent folder")
    }

    func testResettingSettingsKeepsAByteIdenticalBackupAndReturnsToOnboarding() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-reset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("settings.json")
        var original = Settings(roots: [URL(fileURLWithPath: "/code")])
        original.scanDepth = 6
        try original.save(to: file)
        let before = try Data(contentsOf: file)
        let store = SettingsStore(url: file, debounce: .milliseconds(10))
        let model = AppModel(client: FakeEngineClient(snapshots: [Fixtures.sample]), store: store)
        model.startScan()
        await settle(model)

        model.resetSettings()

        XCTAssertEqual(model.settings, Settings())
        XCTAssertEqual(model.overviewState, .needsFolders)
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("settings.json.reset-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(backups[0])), before)
    }

    func testRemovingRepositoryOverridesDropsTheEntryAndRescans() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.updateSettings { $0.repos[Fixtures.root.path] = RepoOverrides(defaultBranch: "trunk") }
        await settle(model)

        model.removeRepoOverrides(for: Fixtures.root)

        XCTAssertNil(model.settings.repos[Fixtures.root.path])
        XCTAssertTrue(model.isScanning)
    }

    func testHidingARepositoryIgnoresItRescansAndSaysHowToGetItBack() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)

        model.hideRepository(Fixtures.root)

        XCTAssertEqual(model.settings.repos[Fixtures.root.path]?.isIgnored, true)
        XCTAssertTrue(model.isScanning, "hiding changes what is found, so the scan runs again")
        XCTAssertTrue(model.notice?.contains(Fixtures.sample.repo.name) == true)
        XCTAssertTrue(model.notice?.contains("Settings") == true)
    }

    func testHidingKeepsTheRepositorysOtherOverrides() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.updateSettings { $0.repos[Fixtures.root.path] = RepoOverrides(defaultBranch: "trunk") }
        await settle(model)

        model.hideRepository(Fixtures.root)

        XCTAssertEqual(model.settings.repos[Fixtures.root.path]?.defaultBranch, "trunk")
        XCTAssertEqual(model.settings.repos[Fixtures.root.path]?.isIgnored, true)
    }

    func testShowingAHiddenRepositoryAgainDropsAnOverrideThatHasNothingElseInIt() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.hideRepository(Fixtures.root)
        await settle(model)

        model.showRepository(Fixtures.root)

        XCTAssertNil(model.settings.repos[Fixtures.root.path])
    }

    func testShowingAHiddenRepositoryAgainKeepsItsOtherOverrides() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.updateSettings {
            $0.repos[Fixtures.root.path] = RepoOverrides(defaultBranch: "trunk", isIgnored: true)
        }
        await settle(model)

        model.showRepository(Fixtures.root)

        XCTAssertEqual(model.settings.repos[Fixtures.root.path], RepoOverrides(defaultBranch: "trunk"))
    }

    func testToolStatusComesFromTheEngineClient() async {
        let (model, _) = makeModel([])
        XCTAssertEqual(model.toolStatus, .unknown)

        await model.refreshToolStatus()

        XCTAssertEqual(model.toolStatus.gitVersion, "2.54.0 (Apple Git-157)")
        XCTAssertEqual(model.toolStatus.gitHubCLI, .installed(version: "2.98.0", path: "/opt/homebrew/bin/gh"))
    }
}
