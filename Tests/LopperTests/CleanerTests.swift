import XCTest
@testable import Lopper

final class CleanerTests: XCTestCase {
    private func makeCleaner(_ repo: TestRepo) -> (Cleaner, UndoLog) {
        let log = UndoLog(url: repo.sandbox.appendingPathComponent("undo-log.jsonl"))
        let cleaner = Cleaner(inspector: RepoInspector(), undoLog: log)
        return (cleaner, log)
    }

    private func baseRepo() throws -> TestRepo {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n", ".gitignore": "node_modules\n"])
        return repo
    }

    private func branchExists(_ repo: TestRepo, _ name: String) -> Bool {
        (try? repo.git("rev-parse", "--verify", "--quiet", "refs/heads/\(name)")) != nil
    }

    /// Creates a branch that has been merged into main with a merge commit and returns its tip.
    private func mergedBranch(_ repo: TestRepo, _ name: String) throws -> String {
        try repo.git("checkout", "-b", name)
        let tip = try repo.commit("work on \(name)", files: ["\(name).txt": name])
        try repo.git("checkout", "main")
        try repo.git("merge", "--no-ff", "-m", "merge \(name)", name)
        return tip
    }

    func testDeleteSafeBranchWritesKeepAliveRefAndUndoRecord() async throws {
        let repo = try baseRepo()
        let tip = try mergedBranch(repo, "done")
        let (cleaner, log) = makeCleaner(repo)

        let outcome = await cleaner.deleteBranch(repoRoot: repo.root, name: "done", approved: .safe)

        guard case .removed(let record) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(branchExists(repo, "done"))
        XCTAssertEqual(record.tip, tip)
        XCTAssertEqual(try repo.sha(record.trashRef), tip)
        let logged = await log.all()
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged[0].status, .completed)
    }

    func testKeepAliveRefSurvivesAggressiveGarbageCollection() async throws {
        let repo = try baseRepo()
        // Unmerged work, deleted on explicit user approval of a Review item.
        try repo.git("checkout", "-b", "abandoned")
        let tip = try repo.commit("only copy of this work", files: ["w.txt": "w"])
        try repo.git("checkout", "main")
        let (cleaner, _) = makeCleaner(repo)

        let outcome = await cleaner.deleteBranch(repoRoot: repo.root, name: "abandoned", approved: .review)
        guard case .removed = outcome else { return XCTFail("\(outcome)") }

        try repo.git("reflog", "expire", "--expire=now", "--all")
        try repo.git("gc", "--prune=now")
        XCTAssertEqual(try repo.git("cat-file", "-t", tip), "commit")
    }

    func testRestoreBringsBranchBackAtTheSameSha() async throws {
        let repo = try baseRepo()
        let tip = try mergedBranch(repo, "done")
        let (cleaner, _) = makeCleaner(repo)
        guard case .removed(let record) = await cleaner.deleteBranch(
            repoRoot: repo.root, name: "done", approved: .safe) else { return XCTFail() }

        let outcome = await cleaner.restore(record)

        guard case .restored(let restored) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(restored.status, .restored)
        XCTAssertEqual(try repo.sha("done"), tip)
        let trashStillThere = (try? repo.git("rev-parse", "--verify", "--quiet", record.trashRef)) != nil
        XCTAssertFalse(trashStillThere)
    }

    func testRestoreUsesSuffixWhenNameWasRecreated() async throws {
        let repo = try baseRepo()
        let tip = try mergedBranch(repo, "done")
        let (cleaner, _) = makeCleaner(repo)
        guard case .removed(let record) = await cleaner.deleteBranch(
            repoRoot: repo.root, name: "done", approved: .safe) else { return XCTFail() }
        try repo.git("branch", "done", "main")

        guard case .restored = await cleaner.restore(record) else { return XCTFail() }
        XCTAssertEqual(try repo.sha("done-restored"), tip)
    }

    func testSkipsWhenBranchGainedUnmergedWorkAfterApproval() async throws {
        let repo = try baseRepo()
        _ = try mergedBranch(repo, "done")
        try repo.git("checkout", "done")
        try repo.commit("new work after the user looked", files: ["late.txt": "late"])
        try repo.git("checkout", "main")
        let (cleaner, _) = makeCleaner(repo)

        let outcome = await cleaner.deleteBranch(repoRoot: repo.root, name: "done", approved: .safe)

        guard case .skipped(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.contains("Verdict changed"), reason)
        XCTAssertTrue(branchExists(repo, "done"))
    }

    func testNeverDeletesProtectedBranches() async throws {
        let repo = try baseRepo()
        try repo.git("branch", "develop")
        let (cleaner, log) = makeCleaner(repo)

        for name in ["main", "develop"] {
            let outcome = await cleaner.deleteBranch(repoRoot: repo.root, name: name, approved: .review)
            guard case .skipped = outcome else { return XCTFail("\(name): \(outcome)") }
            XCTAssertTrue(branchExists(repo, name))
        }
        let logged = await log.all()
        XCTAssertTrue(logged.isEmpty)
    }

    func testRemoveCleanWorktreeThenRestoreIt() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-done")
        try repo.git("worktree", "add", "-b", "done", wt.path)
        try repo.commit("work", files: ["d.txt": "d"], in: wt)
        try repo.git("merge", "--no-ff", "-m", "merge done", "done")
        let (cleaner, _) = makeCleaner(repo)

        let outcome = await cleaner.removeWorktree(repoRoot: repo.root, path: wt, approved: .safe)
        guard case .removed(let record) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path))
        XCTAssertTrue(branchExists(repo, "done"), "removing a worktree keeps its branch")

        guard case .restored = await cleaner.restore(record) else { return XCTFail() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.appendingPathComponent("d.txt").path))
        XCTAssertEqual(try repo.git("rev-parse", "--abbrev-ref", "HEAD", in: wt), "done")
    }

    func testRemoveWorktreeWithOnlyNodeModulesSucceeds() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-modules")
        try repo.git("worktree", "add", "-b", "modules", wt.path)
        try FileManager.default.createDirectory(
            at: wt.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try "x".write(to: wt.appendingPathComponent("node_modules/pkg/i.js"), atomically: true, encoding: .utf8)
        let (cleaner, _) = makeCleaner(repo)

        let outcome = await cleaner.removeWorktree(repoRoot: repo.root, path: wt, approved: .safe)

        guard case .removed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path))
    }

    func testDirtyWorktreeIsNeverForceRemoved() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-dirty")
        try repo.git("worktree", "add", "-b", "dirty", wt.path)
        try "precious".write(to: wt.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)
        let (cleaner, _) = makeCleaner(repo)

        // Safe approval: verdict is Review, so it is skipped.
        guard case .skipped = await cleaner.removeWorktree(repoRoot: repo.root, path: wt, approved: .safe)
        else { return XCTFail() }
        // Even explicit Review approval cannot force it: git refuses and the files stay.
        guard case .failed = await cleaner.removeWorktree(repoRoot: repo.root, path: wt, approved: .review)
        else { return XCTFail() }
        XCTAssertEqual(try String(contentsOf: wt.appendingPathComponent("app.txt"), encoding: .utf8), "precious")
    }

    func testMainWorktreeIsNeverRemoved() async throws {
        let repo = try baseRepo()
        let (cleaner, _) = makeCleaner(repo)
        guard case .skipped = await cleaner.removeWorktree(repoRoot: repo.root, path: repo.root, approved: .review)
        else { return XCTFail() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.root.path))
    }

    func testExpireTrashRemovesOldKeepAliveRefsOnly() async throws {
        let repo = try baseRepo()
        _ = try mergedBranch(repo, "old")
        _ = try mergedBranch(repo, "recent")
        let (cleaner, log) = makeCleaner(repo)
        let longAgo = Date().addingTimeInterval(-40 * 86_400)
        guard case .removed(let oldRecord) = await cleaner.deleteBranch(
            repoRoot: repo.root, name: "old", approved: .safe, now: longAgo) else { return XCTFail() }
        guard case .removed(let recentRecord) = await cleaner.deleteBranch(
            repoRoot: repo.root, name: "recent", approved: .safe) else { return XCTFail() }

        let expired = await cleaner.expireTrash(retentionDays: 30)

        XCTAssertEqual(expired, 1)
        XCTAssertNil(try? repo.git("rev-parse", "--verify", "--quiet", oldRecord.trashRef))
        XCTAssertNotNil(try? repo.git("rev-parse", "--verify", "--quiet", recentRecord.trashRef))
        let statuses = Dictionary(uniqueKeysWithValues: await log.all().map { ($0.id, $0.status) })
        XCTAssertEqual(statuses[oldRecord.id], .expired)
        XCTAssertEqual(statuses[recentRecord.id], .completed)
    }

    func testUndoLogKeepsLatestStatusPerRecord() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-log-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = UndoLog(url: url)
        var record = UndoRecord(
            timestamp: Date(), repoPath: "/r", action: .deleteBranch, branch: "b", tip: "abc",
            upstream: nil, worktreePath: nil, trashRef: "refs/lopper/trash/1/b", status: .pending)
        try await log.append(record)
        record.status = .completed
        try await log.append(record)

        let all = await log.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].status, .completed)
    }

    func testPruneWorktreeRegistrationsRemovesOnlyDeadEntries() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-gone")
        try repo.git("worktree", "add", "-b", "gone", wt.path)
        try FileManager.default.removeItem(at: wt)
        let (cleaner, _) = makeCleaner(repo)

        try await cleaner.pruneWorktreeRegistrations(repoRoot: repo.root)

        XCTAssertFalse(try repo.git("worktree", "list").contains("wt-gone"))
        XCTAssertTrue(branchExists(repo, "gone"))
    }

    func testWorktreeWithSpacesAndAccentsCanBeRemovedAndRestored() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("Mes Projets/arbre é")
        try FileManager.default.createDirectory(
            at: wt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try repo.git("worktree", "add", "-b", "fait", wt.path)
        try repo.commit("work", files: ["d.txt": "d"], in: wt)
        try repo.git("merge", "--no-ff", "-m", "merge fait", "fait")
        let (cleaner, _) = makeCleaner(repo)

        guard case .removed(let record) = await cleaner.removeWorktree(
            repoRoot: repo.root, path: wt, approved: .safe) else { return XCTFail() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path))

        guard case .restored = await cleaner.restore(record) else { return XCTFail() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.appendingPathComponent("d.txt").path))
    }
}
