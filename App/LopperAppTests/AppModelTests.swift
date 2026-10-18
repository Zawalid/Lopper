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

    func testAWorktreeAndItsBranchCountAsOneItemRemoved() async {
        let (model, client) = makeModel([Fixtures.sample], sizes: ["/code/wt/feat/in-worktree": 52_000_000])
        client.emitsBranchFollowUps = true
        model.startScan()
        await settle(model, sizes: 1)
        model.beginCleanAllSafe()
        let selected = model.clean?.includedRows.count ?? 0
        model.runClean()
        await waitUntil { model.clean?.phase == .finished }

        XCTAssertGreaterThan(client.cleanedItems.count, 0)
        XCTAssertEqual(model.clean?.removedCount, selected, "what was selected is what was removed, not the git steps")
        XCTAssertEqual(model.toast?.removed, selected)
        XCTAssertEqual(model.clean?.problemCount, 0)
    }

    func testAFailedFollowUpBranchDeletionIsReportedAsNotRemovedButTheRowStillCounts() async {
        let (model, client) = makeModel([Fixtures.sample], sizes: ["/code/wt/feat/in-worktree": 52_000_000])
        client.emitsBranchFollowUps = true
        let base = client.cleanOutcome
        client.cleanOutcome = { item in
            if case .branch(_, let name, _) = item, name == "feat/in-worktree" {
                return .failed(message: "branch is checked out elsewhere")
            }
            return base(item)
        }
        model.startScan()
        await settle(model, sizes: 1)
        model.beginCleanAllSafe()
        let selected = model.clean?.includedRows.count ?? 0
        model.runClean()
        await waitUntil { model.clean?.phase == .finished }

        XCTAssertEqual(model.clean?.removedCount, selected)
        XCTAssertEqual(model.clean?.problemCount, 1)
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

    // MARK: Triage and snooze

    func testTheFocusedRowKnowsItsPlaceInTheRepositoryQueue() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        model.route = .repo(Fixtures.sample.repo.id)
        let visible = model.visibleRows(forRepo: Fixtures.sample.repo.id)
        XCTAssertGreaterThan(visible.count, 1)

        model.focusedRowID = visible[0].id
        XCTAssertEqual(model.triagePosition?.index, 1)
        XCTAssertEqual(model.triagePosition?.total, visible.count)
        XCTAssertNil(model.triagePosition?.previousID)

        model.focusNextRow()
        XCTAssertEqual(model.focusedRowID, visible[1].id)
        model.focusPreviousRow()
        XCTAssertEqual(model.focusedRowID, visible[0].id)
    }

    func testStepPastTheLastRowStaysPut() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        model.route = .repo(Fixtures.sample.repo.id)
        let last = model.visibleRows(forRepo: Fixtures.sample.repo.id).last!
        model.focusedRowID = last.id

        model.focusNextRow()

        XCTAssertEqual(model.focusedRowID, last.id)
    }

    func testSnoozingAnItemHidesItFromWorthALookUntilItWakes() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        let review = model.allRows.first { $0.verdict == .review }!
        let now = Date()

        model.snooze(review, for: .oneWeek, now: now)

        XCTAssertTrue(model.isSnoozed(review, now: now))
        XCTAssertFalse(model.rowsToConsider(now: now).contains { $0.id == review.id })
        XCTAssertEqual(model.confirmation, "Snoozed for a week")

        model.wake(review)
        XCTAssertFalse(model.isSnoozed(review, now: now))
        XCTAssertTrue(model.rowsToConsider(now: now).contains { $0.id == review.id })
    }

    // MARK: Keeping a branch

    func testKeepingABranchAddsItToThatRepositorysProtectedListAlongsideTheGlobalOnes() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        let global = model.settings.protectedPatterns

        model.keepBranch("feat/old", in: Fixtures.root)

        XCTAssertEqual(model.settings.repos[Fixtures.root.path]?.protectedPatterns, global + ["feat/old"])
        XCTAssertTrue(model.isKeptBranch("feat/old", in: Fixtures.root))
        XCTAssertTrue(model.isScanning, "protection changes verdicts, so it rescans")
        XCTAssertEqual(model.confirmation, "Keeping feat/old. Lopper will not remove it.")
    }

    func testKeepingTheSameBranchTwiceDoesNotDuplicateIt() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.keepBranch("feat/old", in: Fixtures.root)
        model.keepBranch("feat/old", in: Fixtures.root)

        let list = model.settings.repos[Fixtures.root.path]?.protectedPatterns ?? []
        XCTAssertEqual(list.filter { $0 == "feat/old" }.count, 1)
    }

    func testStopKeepingARepositoryGoesBackToTheGlobalListWhenNothingElseIsCustom() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.keepBranch("feat/old", in: Fixtures.root)

        model.stopKeepingBranch("feat/old", in: Fixtures.root)

        XCTAssertNil(model.settings.repos[Fixtures.root.path], "an override with nothing in it is removed")
        XCTAssertFalse(model.isKeptBranch("feat/old", in: Fixtures.root))
    }

    func testStopKeepingKeepsTheOtherBranchesYouProtected() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.keepBranch("feat/a", in: Fixtures.root)
        model.keepBranch("feat/b", in: Fixtures.root)

        model.stopKeepingBranch("feat/a", in: Fixtures.root)

        XCTAssertFalse(model.isKeptBranch("feat/a", in: Fixtures.root))
        XCTAssertTrue(model.isKeptBranch("feat/b", in: Fixtures.root))
    }

    func testAPatternMatchIsNotReportedAsKeptByYou() {
        let (model, _) = makeModel([])
        // "main" is in the global list; that is the repository's rule, not something this person chose.
        XCTAssertFalse(model.isKeptBranch("main", in: Fixtures.root))
    }

    // MARK: Remote

    func testRemoteURLComesFromTheRowsRepository() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        let row = model.allRows[0]

        XCTAssertEqual(model.remoteURL(for: row), Fixtures.sample.repo.remoteURL)
        XCTAssertNotNil(model.remoteURL(for: row))
    }

    // MARK: GitHub CLI note

    private func snapshot(remote: String?, prDetection: Bool) -> RepoSnapshot {
        RepoSnapshot(
            repo: Repo(root: URL(fileURLWithPath: "/code/r"), name: "r", defaultBranch: "main", remoteURL: remote),
            branches: [], worktrees: [], prDetectionAvailable: prDetection, scannedAt: Date())
    }

    func testTheGitHubCliNoteAppearsOnlyForRepositoriesThatLiveOnGitHub() async {
        let github = makeModel([snapshot(remote: "git@github.com:acme/r.git", prDetection: false)]).0
        github.startScan()
        await settle(github)
        XCTAssertTrue(github.prDetectionNote)

        let local = makeModel([snapshot(remote: nil, prDetection: false)]).0
        local.startScan()
        await settle(local)
        XCTAssertFalse(local.prDetectionNote, "a repository with no remote has no pull requests to find")

        let gitlab = makeModel([snapshot(remote: "git@gitlab.com:acme/r.git", prDetection: false)]).0
        gitlab.startScan()
        await settle(gitlab)
        XCTAssertFalse(gitlab.prDetectionNote, "the GitHub CLI cannot help with another host")
    }

    func testTheNoteStaysAwayWhenPullRequestDetectionWorks() async {
        let working = makeModel([snapshot(remote: "git@github.com:acme/r.git", prDetection: true)]).0
        working.startScan()
        await settle(working)

        XCTAssertFalse(working.prDetectionNote)
    }

    // MARK: Item details

    func testDetailsAreLoadedOnceAndCached() async {
        let (model, client) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        let row = model.allRows.first { $0.kind == .branch }!
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        client.checkouts[row.title] = date
        client.pullRequests[row.title] = PullRequestStatus(
            number: 61, title: "feat", state: .open, isDraft: false, review: .approved, checks: .passing, url: nil)

        await model.loadDetails(for: row)
        await model.loadDetails(for: row)

        XCTAssertEqual(model.lastCheckedOut(for: row), date)
        XCTAssertEqual(model.pullRequest(for: row)?.number, 61)
        XCTAssertEqual(client.checkoutRequests, 1)
        XCTAssertEqual(client.pullRequestRequests, 1)
    }

    func testAnItemWithoutAPullRequestIsRememberedAsHavingNone() async {
        let (model, client) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        let row = model.allRows.first { $0.kind == .branch }!

        XCTAssertFalse(model.hasLoadedPullRequest(for: row))
        await model.loadDetails(for: row)
        await model.loadDetails(for: row)

        XCTAssertTrue(model.hasLoadedPullRequest(for: row))
        XCTAssertNil(model.pullRequest(for: row))
        XCTAssertEqual(client.pullRequestRequests, 1, "a missing pull request is not asked for again")
    }

    // MARK: Branch history

    func testHistoryIsLoadedOnceAndServedFromTheCache() async {
        let (model, client) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        let row = model.allRows.first { $0.kind == .branch }!
        client.histories[row.facts.tip ?? ""] = BranchHistory(
            comparedTo: "main",
            commits: [CommitSummary(hash: "abc1234", subject: "feat: thing", author: "Ada", date: Date())],
            totalCommits: 1, diff: DiffSummary(files: 2, insertions: 10, deletions: 1))

        await model.loadHistory(for: row)
        await model.loadHistory(for: row)

        XCTAssertEqual(model.branchHistory(for: row)?.commits.first?.subject, "feat: thing")
        XCTAssertEqual(client.historyRequests, 1)
    }

    func testHistoryForAnItemThatWasNeverLoadedIsNil() {
        let (model, _) = makeModel([])
        XCTAssertNil(model.branchHistory(for: RowMapper.rows(for: Fixtures.sample, sizes: [:])[0]))
    }

    // MARK: History entries

    private func undoRecord(
        _ action: UndoAction, branch: String, batch: UUID = UUID(), status: UndoStatus = .completed
    ) -> UndoRecord {
        UndoRecord(
            timestamp: Date(), repoPath: "/code/api", action: action, branch: branch, tip: "abc", upstream: nil,
            worktreePath: action == .removeWorktree ? "/code/wt/\(branch)" : nil,
            trashRef: "refs/lopper/\(UUID().uuidString)", status: status, batchID: batch)
    }

    func testRestoringAnEntryBringsBackTheBranchBeforeTheWorktree() async {
        let (model, client) = makeModel([])
        let batch = UUID()
        let worktree = undoRecord(.removeWorktree, branch: "feat/a", batch: batch)
        let branch = undoRecord(.deleteBranch, branch: "feat/a", batch: batch)
        let entry = HistoryBuilder.entries(from: [worktree, branch])[0]

        model.restore(entry)
        await waitUntil { client.restoredRecords.count == 2 }

        XCTAssertEqual(client.restoredRecords.map(\.action), [.deleteBranch, .removeWorktree])
        await waitUntil { model.confirmation != nil }
        XCTAssertEqual(model.confirmation, "Restored 1 item", "a worktree and its branch are one thing")
    }

    func testRestoringAnEntryOnlyTouchesRecordsThatAreStillRemoved() async {
        let (model, client) = makeModel([])
        let batch = UUID()
        let entry = HistoryBuilder.entries(from: [
            undoRecord(.removeWorktree, branch: "feat/a", batch: batch, status: .restored),
            undoRecord(.deleteBranch, branch: "feat/a", batch: batch),
        ])[0]

        model.restore(entry)
        await waitUntil { client.restoredRecords.count == 1 }

        XCTAssertEqual(client.restoredRecords.map(\.action), [.deleteBranch])
    }

    func testRestoringABatchCountsItemsNotRecords() async {
        let (model, client) = makeModel([])
        let batch = UUID()
        client.restoreBatchOutcomes = [
            .restored(undoRecord(.deleteBranch, branch: "feat/a", batch: batch)),
            .restored(undoRecord(.removeWorktree, branch: "feat/a", batch: batch)),
            .restored(undoRecord(.deleteBranch, branch: "feat/b", batch: batch)),
        ]

        model.restoreBatch(batch)
        await waitUntil { model.confirmation != nil }

        XCTAssertEqual(model.confirmation, "Restored 2 items")
    }

    func testCleaningHandsTheEngineTheSizeOfEachWorktreeItRemoves() async {
        let (model, client) = makeModel([Fixtures.sample], sizes: ["/code/wt/feat/in-worktree": 52_000_000])
        model.startScan()
        await settle(model, sizes: 1)

        model.beginCleanAllSafe()
        model.runClean()
        await waitUntil { model.clean?.phase == .finished }

        XCTAssertEqual(client.lastSizeHints["worktree:/code/wt/feat/in-worktree"], 52_000_000)
    }

    // MARK: Confirmations

    func testAConfirmationAppearsAndClearsItself() async {
        let (model, _) = makeModel([])
        model.confirmationDuration = .milliseconds(60)

        model.confirm("Copied")
        XCTAssertEqual(model.confirmation, "Copied")

        await waitUntil { model.confirmation == nil }
        XCTAssertNil(model.confirmation)
    }

    func testANewerConfirmationIsNotClearedByTheOlderTimer() async {
        let (model, _) = makeModel([])
        model.confirmationDuration = .milliseconds(150)

        model.confirm("first")
        try? await Task.sleep(for: .milliseconds(90))
        model.confirm("second")
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.confirmation, "second", "the first timer fired at 150 ms and must not clear the second")
        await waitUntil { model.confirmation == nil }
        XCTAssertNil(model.confirmation)
    }

    func testCopyingPutsTheTextOnTheClipboardHandlerAndConfirms() {
        let (model, _) = makeModel([])
        var copied: [String] = []
        model.copyHandler = { copied.append($0) }

        model.copy("feat/x", confirming: "Copied branch name")

        XCTAssertEqual(copied, ["feat/x"])
        XCTAssertEqual(model.confirmation, "Copied branch name")
    }

    func testAddingAThrowawayNameConfirmsIt() {
        let (model, _) = makeModel([])

        model.addThrowaway(name: ".turbo", repoRoot: URL(fileURLWithPath: "/code/api"))

        XCTAssertEqual(model.confirmation, "Added .turbo to this repository's throwaway names")
    }

    func testASuccessfulRestoreConfirmsHowManyItemsCameBack() async {
        let (model, client) = makeModel([Fixtures.sample])
        let record = UndoRecord(
            timestamp: Date(), repoPath: "/code/api", action: .deleteBranch, branch: "feat/x", tip: "abc",
            upstream: nil, worktreePath: nil, trashRef: "refs/lopper/x", status: .restored, batchID: UUID())
        client.restoreBatchOutcomes = [.restored(record), .restored(record)]

        model.restoreBatch(UUID())
        await waitUntil { model.confirmation != nil }

        XCTAssertEqual(model.confirmation, "Restored 2 items")
    }

    func testAFailedRestoreDoesNotClaimSuccess() async {
        let (model, client) = makeModel([Fixtures.sample])
        client.restoreBatchOutcomes = [.failed(message: "nope")]

        model.restoreBatch(UUID())
        await waitUntil { model.notice != nil }

        XCTAssertNil(model.confirmation)
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

    func testIgnoringARepositoryDropsItAtOnceWithoutScanningAgain() async {
        let (model, client) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        let scans = client.scanRequests

        model.updateSettings { $0.repos[Fixtures.root.path, default: RepoOverrides()].isIgnored = true }

        XCTAssertFalse(model.isScanning, "hiding finds nothing new, so nothing is scanned")
        XCTAssertEqual(client.scanRequests, scans)
        XCTAssertTrue(model.summaries.isEmpty, "the repository is gone from what is shown")
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
        XCTAssertFalse(model.isScanning, "hiding drops the repository from what is loaded; no rescan")
        XCTAssertTrue(model.summaries.isEmpty)
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

    func testCleaningOneRepositoryTakesOnlyItsSafeRows() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        let id = Fixtures.sample.repo.id

        model.beginCleanSafe(inRepo: id)

        let rows = model.clean?.rows ?? []
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.verdict == .safe && $0.repoRoot == Fixtures.sample.repo.root })
    }

    func testCleaningARepositoryThatHasNothingSafeOpensNoSheet() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)

        model.beginCleanSafe(inRepo: "/does/not/exist")

        XCTAssertNil(model.clean)
    }

    func testOpeningARepositoryCanSetTheVerdictFilterAtTheSameTime() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)

        model.openRepository(Fixtures.sample.repo.id, showing: .review)

        XCTAssertEqual(model.route, .repo(Fixtures.sample.repo.id))
        XCTAssertEqual(model.verdictFilter, .review)
    }

    func testTheFirstRepositoryWithItemsToReviewIsTheOneWithTheMost() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)

        XCTAssertEqual(model.repositoryWithMostToReview?.id, Fixtures.sample.repo.id)
    }

    func testARequestedSettingsPaneIsHandedOverOnceAndThenForgotten() {
        let (model, _) = makeModel([])
        XCTAssertNil(model.takeRequestedSettingsPane())

        model.requestSettingsPane(.folders)

        XCTAssertEqual(model.takeRequestedSettingsPane(), .folders)
        XCTAssertNil(model.takeRequestedSettingsPane())
    }

    func testToolStatusComesFromTheEngineClient() async {
        let (model, _) = makeModel([])
        XCTAssertEqual(model.toolStatus, .unknown)

        await model.refreshToolStatus()

        XCTAssertEqual(model.toolStatus.gitVersion, "2.54.0 (Apple Git-157)")
        XCTAssertEqual(model.toolStatus.gitHubCLI, .installed(version: "2.98.0", path: "/opt/homebrew/bin/gh"))
    }
    // MARK: Setup problems

    func testMissingGitIsASetupIssueOnlyOnceTheCheckFinished() async {
        let (model, client) = makeModel([])
        client.tools = ToolStatus(gitVersion: nil, gitHubCLI: .notInstalled)
        XCTAssertNil(model.setupIssue, "a slow check must not look like missing git")

        await model.refreshToolStatus()

        XCTAssertEqual(model.setupIssue, .gitMissing)
    }

    func testRecheckClearsTheGitIssueOnceToolsAreInstalled() async {
        let (model, client) = makeModel([])
        client.tools = ToolStatus(gitVersion: nil, gitHubCLI: .notInstalled)
        await model.refreshToolStatus()
        XCTAssertEqual(model.setupIssue, .gitMissing)

        client.tools = ToolStatus(gitVersion: "2.54.0", gitHubCLI: .notInstalled)
        await model.recheckSetup()
        await settle(model)

        XCTAssertNil(model.setupIssue)
    }

    func testAScanSkipsBlockedFoldersAndKeepsTheOthers() async {
        let good = URL(fileURLWithPath: "/code")
        let blocked = URL(fileURLWithPath: "/Users/someone/Documents")
        let client = FakeEngineClient(snapshots: [Fixtures.sample])
        client.folderAccessOverrides[blocked.canonicalized.path] = .denied
        let store = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-test-settings-\(UUID().uuidString).json"))
        let model = AppModel(client: client, store: store, settings: Settings(roots: [good, blocked]))

        model.startScan()
        await settle(model)

        XCTAssertEqual(model.summaries.count, 1)
        XCTAssertEqual(model.unreadableFolders.map(\.path), [blocked])
        XCTAssertNil(model.setupIssue, "one blocked folder is a notice, not a blocked app")
    }

    func testEveryFolderBlockedBecomesASetupIssueAndShowsNoStaleResults() async {
        let (model, client) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        XCTAssertEqual(model.summaries.count, 1)

        client.folderAccessOverrides[URL(fileURLWithPath: "/code").canonicalized.path] = .denied
        model.startScan()
        await waitUntil { model.setupIssue == .foldersUnreadable }

        XCTAssertEqual(model.setupIssue, .foldersUnreadable)
        XCTAssertTrue(model.summaries.isEmpty)
    }

    func testRecheckScansAgainAfterAccessIsGranted() async {
        let (model, client) = makeModel([Fixtures.sample])
        client.folderAccessOverrides[URL(fileURLWithPath: "/code").canonicalized.path] = .denied
        model.startScan()
        await waitUntil { model.setupIssue == .foldersUnreadable }

        client.folderAccessOverrides = [:]
        await model.recheckSetup()
        await settle(model)

        XCTAssertNil(model.setupIssue)
        XCTAssertEqual(model.summaries.count, 1)
    }

    func testSetupWordsNameTheProblemAndTheFix() {
        let folder = FolderSetting(path: URL(fileURLWithPath: "/Users/a/Documents"))
        XCTAssertEqual(SetupGuide.title(for: .gitMissing, folders: []), "Lopper needs git")
        XCTAssertEqual(SetupGuide.title(for: .foldersUnreadable, folders: [(folder, .denied)]), "Lopper cannot open your folders")
        XCTAssertEqual(SetupGuide.title(for: .foldersUnreadable, folders: [(folder, .missing)]), "Your folders are gone")
        XCTAssertEqual(SetupGuide.reason(for: .denied), "No access")
        XCTAssertEqual(SetupGuide.reason(for: .missing), "Not found")
        XCTAssertEqual(SetupGuide.partialNotice([folder]), "Lopper cannot read Documents, so it was skipped.")
        let many = ["A", "B", "C"].map { FolderSetting(path: URL(fileURLWithPath: "/x/\($0)")) }
        XCTAssertEqual(SetupGuide.partialNotice(many), "Lopper cannot read A and B and 1 more, so they were skipped.")
    }
    // MARK: Only on this Mac

    private func localItem(
        _ kind: LocalOnlyItem.Kind = .unpushedCommits, title: String = "feat/old-2", branch: String? = "feat/old-2",
        path: URL? = nil, root: URL = URL(fileURLWithPath: "/code"), push: String? = "git push"
    ) -> LocalOnlyItem {
        LocalOnlyItem(
            id: "\(kind.rawValue):\(root.path)#\(title)", kind: kind, repoRoot: root, repoName: root.lastPathComponent,
            title: title, detail: "2 commits not on any remote", count: 2, lastTouched: Date(), path: path, branch: branch,
            pushCommand: push)
    }

    func testTheScanLoadsWhatExistsOnlyOnThisMac() async {
        let (model, client) = makeModel([Fixtures.sample])
        client.localOnly = [localItem(), localItem(.stash, title: "stash@{0}", branch: nil, push: nil)]
        XCTAssertEqual(model.localOnlyPageState, .scanning)

        model.startScan()
        await settle(model)
        await waitUntil { model.localOnlyLoaded }

        XCTAssertEqual(model.localOnlySummary, LocalOnlySummary(items: 2, repositories: 1, unpushedCommits: 2))
        XCTAssertEqual(model.localOnlyGroups.count, 1)
        XCTAssertEqual(model.localOnlyGroups.first?.items.count, 2)
        XCTAssertEqual(model.localOnlyPageState, .ready)
    }

    func testAnEmptyListMeansEverythingIsBackedUpOnlyAfterTheLookFinished() async {
        let (model, _) = makeModel([Fixtures.sample])
        XCTAssertEqual(model.localOnlyPageState, .scanning, "not loaded yet is not the same as nothing at risk")

        model.startScan()
        await settle(model)
        await waitUntil { model.localOnlyLoaded }

        XCTAssertEqual(model.localOnlyPageState, .allBackedUp(repositories: 1))
    }

    func testTheInspectorFindsTheItemsThatBelongToABranchRow() async {
        let (model, client) = makeModel([Fixtures.sample])
        let root = Fixtures.sample.repo.root
        client.localOnly = [
            localItem(title: "feat/old-2", branch: "feat/old-2", root: root),
            localItem(title: "other", branch: "other", root: root),
        ]
        model.startScan()
        await settle(model)
        await waitUntil { model.localOnlyLoaded }

        let row = model.allRows.first { $0.kind == .branch && $0.title == "feat/old-2" }
        XCTAssertNotNil(row)
        XCTAssertEqual(row.map { model.localOnlyItems(for: $0).map(\.title) }, ["feat/old-2"])
    }

    func testCopyingAPushCommandCopiesItAndConfirms() {
        let (model, _) = makeModel([])
        var copied: [String] = []
        model.copyHandler = { copied.append($0) }

        model.copyPushCommand(localItem(push: "git -C /code push -u origin feat/x"))
        model.copyPushCommand(localItem(.stash, push: nil))

        XCTAssertEqual(copied, ["git -C /code push -u origin feat/x"], "an item with nothing to push copies nothing")
        XCTAssertEqual(model.confirmation, "Copied the push command")
    }

    func testTheHeadlineCountsItemsAndRepositories() {
        XCTAssertEqual(
            LocalOnlyKindStyle.headline(LocalOnlySummary(items: 1, repositories: 1, unpushedCommits: 1)),
            "1 item in 1 repository exists only on this Mac")
    }
    // MARK: Diagnostics

    func testAScanRecordsHowManyRepositoriesAndHowLongItTook() async {
        let (model, client) = makeModel([Fixtures.sample], failures: [URL(fileURLWithPath: "/code/broken")])
        model.startScan()
        await settle(model)
        await waitUntil { client.diagnostics.contains { $0.kind == .scanFinished } }

        let finished = client.diagnostics.first { $0.kind == .scanFinished }
        XCTAssertEqual(finished?.numbers["repositories"], 1)
        XCTAssertEqual(finished?.numbers["failures"], 1)
        XCTAssertNotNil(finished?.numbers["scanSeconds"])
        XCTAssertNotNil(finished?.numbers["sizeSeconds"])
        await waitUntil { client.diagnostics.contains { $0.kind == .scanFailure } }
        XCTAssertEqual(client.diagnostics.first { $0.kind == .scanFailure }?.message, "broken: boom")
    }

    func testASkippedOrFailedCleanIsRecordedButARemovalIsNot() async {
        let (model, client) = makeModel([Fixtures.sample], sizes: ["/code/wt/feat/in-worktree": 52_000_000])
        let base = client.cleanOutcome
        client.cleanOutcome = { item in
            if case .branch(_, let name, _) = item, name == "feat/old-1" { return .skipped(reason: "Verdict changed") }
            return base(item)
        }
        model.startScan()
        await settle(model, sizes: 1)
        model.beginCleanAllSafe()
        model.runClean()
        await waitUntil { model.clean?.phase == .finished }
        await waitUntil { client.diagnostics.contains { $0.kind == .cleanProblem } }

        let problems = client.diagnostics.filter { $0.kind == .cleanProblem }
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].message.contains("Verdict changed"), problems[0].message)
    }

    func testASetupProblemIsRecordedOnceNotOnEveryCheck() async {
        let (model, client) = makeModel([])
        client.tools = ToolStatus(gitVersion: nil, gitHubCLI: .notInstalled)

        await model.refreshToolStatus()
        await model.refreshToolStatus()
        await waitUntil { !client.diagnostics.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(client.diagnostics.filter { $0.kind == .setupIssue }.count, 1)
    }

    func testTheReportHidesNamesUnlessAskedAndNeverShowsFolderPaths() async {
        let (model, _) = makeModel([Fixtures.sample])
        model.startScan()
        await settle(model)
        await model.refreshToolStatus()
        let branch = model.allRows.first { $0.kind == .branch }?.title ?? "feat/old-1"
        model.record(.cleanProblem, "\(branch) skipped: Verdict changed in /Users/someone/code/api")
        try? await Task.sleep(for: .milliseconds(50))

        let hidden = await model.diagnosticsReport(includeNames: false)
        let shown = await model.diagnosticsReport(includeNames: true)

        XCTAssertFalse(hidden.contains(branch), hidden)
        XCTAssertTrue(hidden.contains("branch-"), hidden)
        XCTAssertTrue(shown.contains(branch), shown)
        XCTAssertFalse(hidden.contains("/Users/someone"), hidden)
        XCTAssertFalse(shown.contains("/Users/someone"), shown)
        XCTAssertTrue(hidden.contains("GitHub CLI: 2.98.0"), hidden)
    }
}
