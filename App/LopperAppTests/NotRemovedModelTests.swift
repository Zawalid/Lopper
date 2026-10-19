import XCTest
import Lopper
@testable import LopperApp

/// The "Not removed" panel and the warning before it: why a worktree was left, which files are in the way, retrying,
/// and moving the folder to the Trash with a copy of everything in it.
@MainActor
final class NotRemovedModelTests: XCTestCase {
    private let gitRefusal =
        "git couldn't complete this step: '/code/wt/notes-wt' contains modified or untracked files, use --force to delete it"

    private func makeModel(extra: [WorktreeEntry] = []) async -> (AppModel, FakeEngineClient) {
        let snapshot = Fixtures.snapshot(
            branches: [Fixtures.branch("main", .protected), Fixtures.branch("done", .safe)],
            worktrees: [Fixtures.worktree("notes-wt", .review, extraFiles: ["notes.md"]), Fixtures.worktree("clean-wt", .safe)]
                + extra)
        let client = FakeEngineClient(snapshots: [snapshot])
        let store = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-test-settings-\(UUID().uuidString).json"))
        let model = AppModel(client: client, store: store, settings: Settings(roots: [URL(fileURLWithPath: "/code")]))
        model.startScan()
        for _ in 0..<300 {
            if case .ready = model.phase { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return (model, client)
    }

    private func row(_ model: AppModel, _ title: String) throws -> CleanupRow {
        try XCTUnwrap(model.allRows.first { $0.title == title }, "no row named \(title)")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Opens the sheet on `rows`, makes the engine refuse the dirty worktree the way git does, and runs it.
    private func cleanWithRefusal(_ model: AppModel, _ client: FakeEngineClient, rows: [CleanupRow]) async {
        let message = gitRefusal
        let base = client.cleanOutcome
        client.cleanOutcome = { item in
            if case .worktree(_, let path, _, _) = item, path.lastPathComponent == "notes-wt" {
                return .failed(message: message)
            }
            return base(item)
        }
        model.beginClean(rows: rows)
        model.runClean()
        await waitUntil { model.clean?.phase == .finished }
    }

    // MARK: Before: the warning

    func testTheReviewSheetFindsWhichSelectedWorktreesHaveFilesGitWillNotLetGo() async throws {
        let (model, client) = await makeModel()
        let dirty = try row(model, "notes-wt")
        let clean = try row(model, "clean-wt")
        client.changesByRow[dirty.id] = WorktreeChanges(files: [WorktreeChange(path: "notes.md", kind: .untracked)], total: 1)
        model.beginClean(rows: [dirty, clean])

        await model.checkForBlockingChanges()

        XCTAssertEqual(model.clean?.blockedRows.map(\.title), ["notes-wt"])
        XCTAssertEqual(client.blockingChangeRequests, [dirty.id], "a worktree with nothing odd about it is not even looked at")
    }

    func testAnIgnoredOnlyFolderIsNotCalledBlockedBecauseGitDoesNotCountIgnoredFiles() async throws {
        let (model, client) = await makeModel()
        let dirty = try row(model, "notes-wt")
        client.changesByRow[dirty.id] = .none
        model.beginClean(rows: [dirty])

        await model.checkForBlockingChanges()

        XCTAssertTrue(model.clean?.blockedRows.isEmpty ?? false)
    }

    func testLeavingThemOutRemovesExactlyThoseFromTheSheet() async throws {
        let (model, client) = await makeModel()
        let dirty = try row(model, "notes-wt")
        let clean = try row(model, "clean-wt")
        client.changesByRow[dirty.id] = WorktreeChanges(files: [WorktreeChange(path: "notes.md", kind: .untracked)], total: 1)
        model.beginClean(rows: [dirty, clean])
        await model.checkForBlockingChanges()

        model.leaveOutBlocked()

        XCTAssertEqual(model.clean?.includedRows.map(\.title), ["clean-wt"])
        XCTAssertTrue(model.clean?.blockedRows.isEmpty ?? false, "the warning goes away once they are left out")
    }

    func testTheSelectionFooterLeavesOutWorktreesThatMayHoldFolderOnlyWork() async throws {
        let (model, _) = await makeModel()
        let dirty = try row(model, "notes-wt")
        let clean = try row(model, "clean-wt")
        model.setSelection([dirty.id, clean.id])
        XCTAssertEqual(model.selectionSummary(shown: model.allRows).folderOnlyWork, 1)

        model.leaveOutFolderOnlyWork()

        XCTAssertEqual(model.checked, [clean.id])
    }

    // MARK: After: why, and which files

    func testARefusalFromGitIsExplainedWithoutGitJargon() async throws {
        let (model, client) = await makeModel()
        await cleanWithRefusal(model, client, rows: [try row(model, "notes-wt"), try row(model, "clean-wt")])

        let outcome = try XCTUnwrap(model.clean?.outcomes.first { $0.status != .removed })

        XCTAssertEqual(outcome.refusal, .hasChanges)
        XCTAssertFalse(outcome.refusal.sentence.contains("--force"))
        XCTAssertEqual(model.clean?.removedCount, 1, "the clean one went")
    }

    func testTheFilesInTheWayAreReadForTheRefusedItemOnlyWhenAsked() async throws {
        let (model, client) = await makeModel()
        let dirty = try row(model, "notes-wt")
        client.changesByRow[dirty.id] = WorktreeChanges(files: [WorktreeChange(path: "notes.md", kind: .untracked)], total: 1)
        await cleanWithRefusal(model, client, rows: [dirty])
        let outcome = try XCTUnwrap(model.clean?.outcomes.first { $0.status != .removed })
        XCTAssertNil(model.clean?.changes[dirty.id])

        await model.loadChanges(forOutcome: outcome.id)

        XCTAssertEqual(model.clean?.changes[dirty.id]?.files.map(\.path), ["notes.md"])
    }

    // MARK: Retry

    func testRetryingAfterTheFolderWasCleanedUpRemovesItAndCountsItInTheTotals() async throws {
        let (model, client) = await makeModel()
        let dirty = try row(model, "notes-wt")
        await cleanWithRefusal(model, client, rows: [dirty])
        let before = try XCTUnwrap(model.clean?.removedCount)
        client.cleanOutcome = { item in
            .removed(UndoRecord(
                timestamp: Fixtures.now, repoPath: "/code/api", action: .removeWorktree, branch: "notes-wt", tip: "abc",
                upstream: nil, worktreePath: "/code/wt/notes-wt", trashRef: "refs/lopper/trash/1/x", status: .completed))
        }
        let outcome = try XCTUnwrap(model.clean?.outcomes.first { $0.status != .removed })

        model.retryNotRemoved([outcome.id])
        await waitUntil { model.clean?.problemCount == 0 }

        XCTAssertEqual(model.clean?.problemCount, 0)
        XCTAssertEqual(model.clean?.removedCount, before + 1)
        XCTAssertNotNil(model.toast, "a retried removal can be undone like any other")
        XCTAssertTrue(model.clean?.working.isEmpty ?? false)
    }

    func testRetryingWhenTheFilesAreStillThereKeepsTheItemListedWithTheSameReason() async throws {
        let (model, client) = await makeModel()
        let dirty = try row(model, "notes-wt")
        await cleanWithRefusal(model, client, rows: [dirty])
        let outcome = try XCTUnwrap(model.clean?.outcomes.first { $0.status != .removed })

        model.retryNotRemoved([outcome.id])
        await waitUntil { model.clean?.working.isEmpty == true }

        XCTAssertEqual(model.clean?.problemCount, 1)
        XCTAssertEqual(model.clean?.outcomes.first { $0.status != .removed }?.refusal, .hasChanges)
    }

    // MARK: Remove anyway, keep a copy

    func testMovingTheFolderToTheTrashMarksItRemovedAndOffersUndo() async throws {
        let (model, client) = await makeModel()
        let dirty = try row(model, "notes-wt")
        await cleanWithRefusal(model, client, rows: [dirty])
        let outcome = try XCTUnwrap(model.clean?.outcomes.first { $0.status != .removed })

        model.removeKeepingCopy(outcomeID: outcome.id)
        await waitUntil { model.clean?.problemCount == 0 }

        XCTAssertEqual(client.keptCopies, [dirty.id])
        XCTAssertEqual(model.clean?.problemCount, 0)
        XCTAssertEqual(model.clean?.removedCount, 1)
        XCTAssertNotNil(model.toast)
    }

    func testOnlyAFolderBlockedByChangesCanBeMovedToTheTrash() async throws {
        let (model, client) = await makeModel()
        let dirty = try row(model, "notes-wt")
        model.clean = CleanState(rows: [dirty])
        model.clean?.phase = .finished
        model.clean?.outcomes = [
            ItemOutcome(id: dirty.cleanupItem?.id ?? "", title: "notes-wt", status: .skipped, message: "The worktree is locked"),
        ]

        model.removeKeepingCopy(outcomeID: dirty.cleanupItem?.id ?? "")
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(client.keptCopies.isEmpty, "a locked worktree is not about files, so the folder is never moved")
    }

    func testAWorktreeAnAgentMayStillBeUsingIsNeverMovedToTheTrash() async throws {
        let measured = Fixtures.agentMeasurements
        let client = FakeEngineClient(snapshots: [Fixtures.agentSample])
        let model = AppModel.preview(
            snapshots: [Fixtures.agentSample], sizes: measured.sizes, activity: measured.activity, route: .agents,
            clock: { Fixtures.now })
        let busy = try XCTUnwrap(model.allRows.first { $0.title == "claude/just-now" })
        XCTAssertNotNil(busy.keepCopyRefusal)
        model.clean = CleanState(rows: [busy])
        model.clean?.phase = .finished
        model.clean?.outcomes = [
            ItemOutcome(id: busy.cleanupItem?.id ?? "", title: busy.title, status: .failed, message: gitRefusal),
        ]

        model.removeKeepingCopy(outcomeID: busy.cleanupItem?.id ?? "")
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(client.keptCopies.isEmpty)
        XCTAssertEqual(model.clean?.problemCount, 1)
    }

    func testAFailedMoveKeepsTheItemListedWithTheReason() async throws {
        let (model, client) = await makeModel()
        let dirty = try row(model, "notes-wt")
        await cleanWithRefusal(model, client, rows: [dirty])
        client.keepCopyOutcome = { _ in .failed(message: "Could not move the folder to the Trash.") }
        let outcome = try XCTUnwrap(model.clean?.outcomes.first { $0.status != .removed })

        model.removeKeepingCopy(outcomeID: outcome.id)
        await waitUntil { model.clean?.working.isEmpty == true && model.clean?.outcomes.first?.message?.contains("Trash") == true }

        XCTAssertEqual(model.clean?.problemCount, 1)
        XCTAssertEqual(model.clean?.removedCount, 0)
        XCTAssertNil(model.toast)
    }
}
