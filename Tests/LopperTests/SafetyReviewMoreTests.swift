import XCTest
@testable import Lopper

/// Independent safety review reproductions, batch 2. Each test asserts the SAFE behaviour; a failure is a finding.
final class SafetyReviewMoreTests: XCTestCase {
    private func makeCleaner(_ repo: TestRepo) -> (Cleaner, UndoLog) {
        let log = UndoLog(url: repo.sandbox.appendingPathComponent("undo-log.jsonl"))
        return (Cleaner(inspector: RepoInspector(), undoLog: log), log)
    }

    private func baseRepo() throws -> TestRepo {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n", ".gitignore": "node_modules\n"])
        return repo
    }

    private func mergedBranchWithWorktree(_ repo: TestRepo, name: String = "done", folder: String = "wt") throws -> URL {
        try repo.git("checkout", "-b", name)
        try repo.commit("work on \(name)", files: ["\(name).txt": name])
        try repo.git("checkout", "main")
        try repo.git("merge", "--no-ff", "-m", "merge \(name)", name)
        let wt = repo.sandbox.appendingPathComponent(folder)
        try repo.git("worktree", "add", wt.path, name)
        return wt
    }

    /// `git status` hides modifications to files flagged skip-worktree, and so does git's own
    /// "is this worktree clean" refusal in `git worktree remove`.
    func testSkipWorktreeEditsAreNotDestroyedByRemoval() async throws {
        let repo = try baseRepo()
        let wt = try mergedBranchWithWorktree(repo)
        try repo.git("update-index", "--skip-worktree", "app.txt", in: wt)
        try "my local edit that exists nowhere else\n".write(
            to: wt.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try repo.git("status", "--porcelain", in: wt), "")

        let (cleaner, _) = makeCleaner(repo)
        let outcome = await cleaner.removeWorktree(
            repoRoot: repo.root, path: wt, approved: .safe, refuseFolderOnlyWork: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path), "removed: \(outcome)")
    }

    func testAssumeUnchangedEditsAreNotDestroyedByRemoval() async throws {
        let repo = try baseRepo()
        let wt = try mergedBranchWithWorktree(repo)
        try repo.git("update-index", "--assume-unchanged", "app.txt", in: wt)
        try "my local edit that exists nowhere else\n".write(
            to: wt.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try repo.git("status", "--porcelain", in: wt), "")

        let (cleaner, _) = makeCleaner(repo)
        let outcome = await cleaner.removeWorktree(
            repoRoot: repo.root, path: wt, approved: .safe, refuseFolderOnlyWork: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path), "removed: \(outcome)")
    }

    /// A tag with the same name as a branch makes `%(refname:short)` return `heads/<name>`.
    func testTagWithBranchNameDoesNotStripProtection() async throws {
        let repo = try baseRepo()
        try repo.git("tag", "main")
        let snapshot = try await RepoInspector().inspect(repoRoot: repo.root)
        let names = snapshot.branches.map(\.name)
        let main = snapshot.branches.first { $0.name.hasSuffix("main") }
        XCTAssertEqual(names, ["main"], "branch names: \(names)")
        XCTAssertEqual(main?.verdict.kind, .protected, "verdict: \(String(describing: main?.verdict))")
    }

    /// Control for the previous test: acting on the mislabelled row still fails closed (main survives).
    func testDeletingTheMislabelledRowFailsClosed() async throws {
        let repo = try baseRepo()
        try repo.git("tag", "main")
        try repo.git("checkout", "-b", "other")
        let (cleaner, _) = makeCleaner(repo)
        let outcome = await cleaner.deleteBranch(repoRoot: repo.root, name: "heads/main", approved: .safe)
        let survived = (try? repo.git("rev-parse", "--verify", "--quiet", "refs/heads/main")) != nil
        XCTAssertTrue(survived, "\(outcome)")
        if case .removed = outcome { XCTFail("unexpected removal \(outcome)") }
    }

    /// Experiment: what happens to a rebase when its branch is deleted underneath it.
    func testRebaseContinuesCleanlyAfterBranchDeleted() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "other")
        try repo.commit("other", files: ["o.txt": "o"])
        try repo.git("checkout", "main")
        try repo.git("checkout", "-b", "topic")
        try repo.commit("t1", files: ["t1.txt": "1"])
        try repo.commit("t2", files: ["t2.txt": "2"])
        try repo.git("checkout", "main")
        try repo.git("merge", "--squash", "topic")
        try repo.git("commit", "-m", "squash topic")
        let wt = repo.sandbox.appendingPathComponent("wt")
        try repo.git("worktree", "add", wt.path, "topic")
        setenv("GIT_SEQUENCE_EDITOR", "sed -i '' 's/^pick/edit/'", 1)
        try repo.git("rebase", "-i", "other", in: wt)
        unsetenv("GIT_SEQUENCE_EDITOR")
        let during = try repo.commit("work added while rebase is stopped", files: ["new.txt": "n"], in: wt)
        let (cleaner, _) = makeCleaner(repo)
        _ = await cleaner.deleteBranch(repoRoot: repo.root, name: "topic", approved: .safe)
        setenv("GIT_EDITOR", "true", 1)
        defer { unsetenv("GIT_EDITOR") }
        let result = try? repo.git("rebase", "--continue", in: wt)
        let status = (try? repo.git("status", "--short", "--branch", in: wt)) ?? "?"
        let holders = (try? repo.git("for-each-ref", "--contains", during)) ?? "?"
        _ = (result, status, holders)
        // The branch being rebased must survive Lopper: the rebase is still working on it.
        XCTAssertNotNil(try? repo.git("rev-parse", "--verify", "--quiet", "refs/heads/topic"), "topic was deleted under a running rebase")
    }

    /// Control: odd worktree paths still resolve to exactly one worktree and remove cleanly.
    func testWorktreePathWithNewlineAndDecomposedUnicodeRemoves() async throws {
        let repo = try baseRepo()
        let wt = try mergedBranchWithWorktree(repo, folder: "wt\nspace e\u{301} x")
        let (cleaner, _) = makeCleaner(repo)
        let outcome = await cleaner.removeWorktree(repoRoot: repo.root, path: wt, approved: .safe)
        guard case .removed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path))
    }

    /// Control: a symlink to the main working directory never removes it.
    func testSymlinkToMainWorktreeIsNeverRemoved() async throws {
        let repo = try baseRepo()
        let link = repo.sandbox.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo.root)
        let (cleaner, _) = makeCleaner(repo)
        let outcome = await cleaner.removeWorktree(repoRoot: repo.root, path: link, approved: .safe)
        if case .removed = outcome { XCTFail("removed main via symlink") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.root.path))
    }

    /// A prunable DETACHED worktree whose folder is gone gets no lopper/saved/ branch (only the 30 day trash ref).
    func testMissingDetachedWorktreeGetsSavedBranch() async throws {
        let repo = try baseRepo()
        let home = repo.sandbox.appendingPathComponent("wtD")
        try repo.git("worktree", "add", "--detach", home.path)
        let sha = try repo.commit("detached only", files: ["d.txt": "d"], in: home)
        try FileManager.default.removeItem(at: home)
        let (cleaner, _) = makeCleaner(repo)
        let outcome = await cleaner.removeWorktree(repoRoot: repo.root, path: home, approved: .review)
        guard case .removed = outcome else { return XCTFail("\(outcome)") }
        let permanent = try repo.git("for-each-ref", "--contains", sha, "refs/heads")
        XCTAssertFalse(permanent.isEmpty, "only refs/lopper/trash (30 days) holds \(sha.prefix(8))")
    }
}
