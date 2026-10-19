import XCTest
@testable import Lopper

private struct TrashInFolder: TrashProvider {
    let folder: URL

    func moveToTrash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

private struct BrokenTrash: TrashProvider {
    func moveToTrash(_ url: URL) throws -> URL { throw CocoaError(.fileWriteNoPermission) }
}

/// Removing a worktree whose folder holds changes git refuses to throw away: the folder goes to the Trash whole, git's
/// record of it is dropped, and History can bring both back.
final class CleanerKeepCopyTests: XCTestCase {
    private struct Fixture {
        let repo: TestRepo
        let log: UndoLog
        let cleaner: Cleaner
        let trash: URL
        let backups: URL
        let worktree: URL
    }

    private func fixture(trash: TrashProvider? = nil, dirty: Bool = true) throws -> Fixture {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n", "staged.txt": "base\n"])
        let worktree = repo.sandbox.appendingPathComponent("wt-feature")
        try repo.git("worktree", "add", "-b", "feature", worktree.path)
        try repo.commit("feature work", files: ["feature.txt": "f"], in: worktree)
        if dirty {
            try "edited".write(to: worktree.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)
            try "notes".write(to: worktree.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
            try "staged edit".write(to: worktree.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
            try repo.git("add", "staged.txt", in: worktree)
        }
        let log = UndoLog(url: repo.sandbox.appendingPathComponent("undo-log.jsonl"))
        let folder = repo.sandbox.appendingPathComponent(".Trash")
        let backups = repo.sandbox.appendingPathComponent("registrations")
        let cleaner = Cleaner(
            inspector: RepoInspector(), undoLog: log, trash: trash ?? TrashInFolder(folder: folder),
            registrationBackups: backups)
        return Fixture(repo: repo, log: log, cleaner: cleaner, trash: folder, backups: backups, worktree: worktree)
    }

    private func listed(_ f: Fixture) throws -> [String] {
        try f.repo.git("worktree", "list", "--porcelain").split(separator: "\n")
            .filter { $0.hasPrefix("worktree ") }.map { String($0.dropFirst("worktree ".count)) }
    }

    private func removeKeepingCopy(_ f: Fixture, approved: VerdictKind = .review) async -> CleanOutcome {
        await f.cleaner.removeWorktreeKeepingCopy(repoRoot: f.repo.root, path: f.worktree, approved: approved)
    }

    // MARK: Removing

    func testAFolderWithChangesIsMovedToTheTrashWholeAndGitsRecordIsDropped() async throws {
        let f = try fixture()

        let outcome = await removeKeepingCopy(f)

        guard case .removed(let record) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(record.action, .trashWorktree)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.worktree.path))
        let trashed = try XCTUnwrap(record.trashedPath)
        XCTAssertEqual(try String(contentsOfFile: trashed + "/app.txt", encoding: .utf8), "edited", "every file is kept")
        XCTAssertEqual(try String(contentsOfFile: trashed + "/notes.md", encoding: .utf8), "notes")
        XCTAssertFalse(try listed(f).contains(f.worktree.path), "git no longer lists the worktree")
        XCTAssertEqual(try f.repo.git("rev-parse", "refs/heads/feature"), record.tip, "the branch stays")
        XCTAssertEqual(try f.repo.sha(record.trashRef), record.tip, "the keep-alive ref pins the commit")
        XCTAssertNotNil(record.registrationBackup)
        let logged = await f.log.all()
        XCTAssertEqual(logged.first?.status, .completed)
    }

    func testRestoringPutsTheFolderAndGitsRecordBackWithEveryEditAndTheStagedState() async throws {
        let f = try fixture()
        guard case .removed(let record) = await removeKeepingCopy(f) else { return XCTFail() }

        let restored = await f.cleaner.restore(record)

        guard case .restored = restored else { return XCTFail("\(restored)") }
        XCTAssertEqual(try String(contentsOf: f.worktree.appendingPathComponent("app.txt"), encoding: .utf8), "edited")
        XCTAssertTrue(try listed(f).contains(f.worktree.path))
        XCTAssertEqual(try f.repo.git("rev-parse", "--abbrev-ref", "HEAD", in: f.worktree), "feature")
        XCTAssertEqual(try f.repo.git("diff", "--cached", "--name-only", in: f.worktree), "staged.txt", "staging survives")
        XCTAssertTrue(try f.repo.git("status", "--porcelain", in: f.worktree).contains("?? notes.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.registrationBackup ?? ""), "the saved copy is cleaned up")
        let logged = await f.log.all()
        XCTAssertEqual(logged.first?.status, .restored)
    }

    func testARestoredWorktreeCanBeRemovedAgainTheSameWay() async throws {
        let f = try fixture()
        guard case .removed(let record) = await removeKeepingCopy(f) else { return XCTFail() }
        guard case .restored = await f.cleaner.restore(record) else { return XCTFail() }

        guard case .removed = await removeKeepingCopy(f) else { return XCTFail("a second removal must work") }
    }

    func testADetachedWorktreeKeepsItsCommitsOnASavedBranch() async throws {
        let f = try fixture()
        try f.repo.git("checkout", "--detach", in: f.worktree)
        let unique = try f.repo.commit("only here", files: ["only.txt": "1"], in: f.worktree)

        guard case .removed(let record) = await removeKeepingCopy(f) else { return XCTFail() }

        let saved = Cleaner.savedBranchName(forWorktreeAt: f.worktree, head: unique)
        XCTAssertEqual(try f.repo.git("rev-parse", "refs/heads/\(saved)"), unique)
        guard case .restored = await f.cleaner.restore(record) else { return XCTFail() }
        XCTAssertEqual(try f.repo.git("rev-parse", "HEAD", in: f.worktree), unique)
    }

    // MARK: What it refuses

    func testItNeverTouchesTheMainWorkingFolder() async throws {
        let f = try fixture()

        let outcome = await f.cleaner.removeWorktreeKeepingCopy(repoRoot: f.repo.root, path: f.repo.root, approved: .review)

        guard case .skipped = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.repo.root.path))
    }

    func testItHonoursTheApprovedVerdict() async throws {
        let f = try fixture()

        // A dirty worktree is a Review item, so approval of Safe must not be enough.
        let outcome = await removeKeepingCopy(f, approved: .safe)

        guard case .skipped = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.worktree.appendingPathComponent("notes.md").path))
    }

    func testAProtectedWorktreeIsNeverMoved() async throws {
        let f = try fixture()
        try f.repo.git("worktree", "lock", f.worktree.path)

        let outcome = await removeKeepingCopy(f)

        guard case .skipped(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.worktree.path))
        XCTAssertTrue(try listed(f).contains(f.worktree.path))
    }

    func testAWorktreeWithAnotherWorktreeInsideItIsLeftAlone() async throws {
        let f = try fixture()
        let inner = f.worktree.appendingPathComponent("inner")
        try f.repo.git("worktree", "add", "-b", "inner", inner.path)

        let outcome = await removeKeepingCopy(f)

        guard case .skipped = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: inner.path))
    }

    func testAMissingFolderIsLeftToTheNormalPrune() async throws {
        let f = try fixture()
        try FileManager.default.removeItem(at: f.worktree)

        let outcome = await removeKeepingCopy(f)

        guard case .skipped = outcome else { return XCTFail("\(outcome)") }
    }

    func testACommitMadeAfterReviewStopsTheRemoval() async throws {
        let f = try fixture()
        var cleaner = f.cleaner
        let repo = f.repo
        let worktree = f.worktree
        cleaner.afterVerifyHook = { _ = try? repo.commit("late work", files: ["late.txt": "l"], in: worktree) }

        let outcome = await cleaner.removeWorktreeKeepingCopy(repoRoot: f.repo.root, path: f.worktree, approved: .review)

        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.worktree.appendingPathComponent("late.txt").path))
        XCTAssertTrue(try listed(f).contains(f.worktree.path))
    }

    // MARK: When something goes wrong

    func testATrashThatFailsLeavesTheFolderAndGitsRecordUntouched() async throws {
        let f = try fixture(trash: BrokenTrash())

        let outcome = await removeKeepingCopy(f)

        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try String(contentsOf: f.worktree.appendingPathComponent("notes.md"), encoding: .utf8), "notes")
        XCTAssertTrue(try listed(f).contains(f.worktree.path))
        XCTAssertTrue(try f.repo.git("status", "--porcelain", in: f.worktree).contains("notes.md"))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: f.backups.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "no saved copy is left behind")
    }

    func testIfGitsRecordCannotBeDroppedTheFolderIsPutBack() async throws {
        let f = try fixture()
        let registrations = f.repo.root.appendingPathComponent(".git/worktrees")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: registrations.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: registrations.path) }

        let outcome = await removeKeepingCopy(f)

        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try String(contentsOf: f.worktree.appendingPathComponent("notes.md"), encoding: .utf8), "notes")
        XCTAssertTrue(try listed(f).contains(f.worktree.path))
    }

    func testRestoreRefusesWhenSomethingIsAlreadyAtTheOriginalPlace() async throws {
        let f = try fixture()
        guard case .removed(let record) = await removeKeepingCopy(f) else { return XCTFail() }
        try FileManager.default.createDirectory(at: f.worktree, withIntermediateDirectories: true)

        let restored = await f.cleaner.restore(record)

        guard case .failed = restored else { return XCTFail("\(restored)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.trashedPath ?? ""), "the folder stays in the Trash")
    }

    func testRestoreRefusesWhenADifferentFolderTookTheNameInTheTrash() async throws {
        let f = try fixture()
        guard case .removed(let record) = await removeKeepingCopy(f) else { return XCTFail() }
        let trashed = try XCTUnwrap(record.trashedPath)
        try FileManager.default.removeItem(atPath: trashed)
        try FileManager.default.createDirectory(atPath: trashed, withIntermediateDirectories: true)

        let restored = await f.cleaner.restore(record)

        guard case .failed = restored else { return XCTFail("\(restored)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.worktree.path))
    }

    func testRestoreRefusesWhenTheBranchIsCheckedOutSomewhereElse() async throws {
        let f = try fixture()
        guard case .removed(let record) = await removeKeepingCopy(f) else { return XCTFail() }
        let other = f.repo.sandbox.appendingPathComponent("wt-other")
        try f.repo.git("worktree", "add", other.path, "feature")

        let restored = await f.cleaner.restore(record)

        guard case .failed = restored else { return XCTFail("\(restored)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.worktree.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.trashedPath ?? ""))
    }

    func testRestoreRecreatesTheBranchIfItWasDeletedInTheMeantime() async throws {
        let f = try fixture()
        guard case .removed(let record) = await removeKeepingCopy(f) else { return XCTFail() }
        try f.repo.git("branch", "-D", "feature")

        let restored = await f.cleaner.restore(record)

        guard case .restored = restored else { return XCTFail("\(restored)") }
        XCTAssertEqual(try f.repo.git("rev-parse", "refs/heads/feature"), record.tip)
    }

    // MARK: Keeping history tidy

    func testAnOldEntryWhoseFolderIsStillInTheTrashIsNotExpired() async throws {
        let f = try fixture()
        guard case .removed(let record) = await removeKeepingCopy(f) else { return XCTFail() }

        let expired = await f.cleaner.expireTrash(retentionDays: 30, now: record.timestamp.addingTimeInterval(90 * 86_400))

        XCTAssertEqual(expired, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.registrationBackup ?? ""), "it can still be restored")
        XCTAssertEqual(try f.repo.sha(record.trashRef), record.tip)
    }

    func testOnceThePersonEmptiedTheTrashTheEntryExpiresAndItsLeftoversGo() async throws {
        let f = try fixture()
        guard case .removed(let record) = await removeKeepingCopy(f) else { return XCTFail() }
        try FileManager.default.removeItem(atPath: try XCTUnwrap(record.trashedPath))

        let expired = await f.cleaner.expireTrash(retentionDays: 30, now: record.timestamp.addingTimeInterval(90 * 86_400))

        XCTAssertEqual(expired, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.registrationBackup ?? ""))
        XCTAssertNil(try? f.repo.sha(record.trashRef))
        let logged = await f.log.all()
        XCTAssertEqual(logged.first?.status, .expired)
    }

    func testABatchRestoreAlsoBringsBackAKeptCopy() async throws {
        let f = try fixture()
        let batch = UUID()
        guard case .removed = await f.cleaner.removeWorktreeKeepingCopy(
            repoRoot: f.repo.root, path: f.worktree, approved: .review, batchID: batch)
        else { return XCTFail() }

        let outcomes = await f.cleaner.restoreBatch(batch)

        XCTAssertEqual(outcomes.count, 1)
        guard case .restored = outcomes[0] else { return XCTFail("\(outcomes)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.worktree.appendingPathComponent("notes.md").path))
    }

    func testOlderBuildsCanStillReadARecordWithoutTheNewField() throws {
        let json = """
        {"action":"removeWorktree","id":"\(UUID().uuidString)","repoPath":"/r","status":"completed","timestamp":"2026-01-01T00:00:00Z","tip":"abc","trashRef":"refs/lopper/trash/1/x"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let record = try decoder.decode(UndoRecord.self, from: Data(json.utf8))

        XCTAssertNil(record.registrationBackup)
    }
}
