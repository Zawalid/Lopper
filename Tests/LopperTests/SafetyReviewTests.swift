import XCTest
@testable import Lopper

/// Independent safety review reproductions. Each test asserts the SAFE behaviour; a failure is a finding.
final class SafetyReviewTests: XCTestCase {
    private func makeCleaner(_ repo: TestRepo) -> (Cleaner, UndoLog) {
        let log = UndoLog(url: repo.sandbox.appendingPathComponent("undo-log.jsonl"))
        return (Cleaner(inspector: RepoInspector(), undoLog: log), log)
    }

    private func baseRepo() throws -> TestRepo {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n", ".gitignore": "node_modules\n"])
        return repo
    }

    private func refExists(_ repo: TestRepo, _ ref: String) -> Bool {
        (try? repo.git("rev-parse", "--verify", "--quiet", ref)) != nil
    }

    // MARK: F1 - git cherry ignores merge commits, so an "evil merge" is invisible

    /// A branch whose only unique content sits in a merge commit (new file added while merging main in)
    /// is called "Content already in the default branch" because `git cherry` skips merge commits.
    func testBranchWithWorkOnlyInMergeCommitIsNotCalledMerged() async throws {
        let repo = try baseRepo()
        // main gets a side branch merged (this is what "update branch" pulls into the feature branch).
        try repo.git("checkout", "-b", "side")
        try repo.commit("s1", files: ["s.txt": "s\n"])
        try repo.git("checkout", "main")
        try repo.git("merge", "--no-ff", "-m", "merge side", "side")
        // feat: one ordinary commit, then a merge of `side` carrying an extra file.
        try repo.git("checkout", "-b", "feat", "HEAD~1")
        let c1 = try repo.commit("c1", files: ["a.txt": "a\n"])
        try repo.git("merge", "--no-commit", "--no-ff", "side")
        try "irreplaceable work that lives only in the merge commit\n"
            .write(to: repo.root.appendingPathComponent("only-here.txt"), atomically: true, encoding: .utf8)
        try repo.git("add", "-A")
        try repo.git("commit", "-m", "merge side into feat, plus new file")
        // "Rebase and merge" of the ordinary commit onto main: same patch, new commit.
        try repo.git("checkout", "main")
        try repo.git("cherry-pick", c1)

        let (cleaner, _) = makeCleaner(repo)
        let entry = try await RepoInspector().inspectBranch(repoRoot: repo.root, name: "feat")
        let onMain = (try? repo.git("cat-file", "-e", "main:only-here.txt")) != nil
        XCTAssertFalse(onMain)
        XCTAssertNotEqual(entry?.verdict.kind, .safe, "evidence: \(String(describing: entry?.evidence))")
        let outcome = await cleaner.deleteBranch(repoRoot: repo.root, name: "feat", approved: .safe)
        if case .removed = outcome { XCTFail("Safe-deleted a branch carrying unique work") }
        XCTAssertNotNil(try? repo.git("rev-parse", "--verify", "--quiet", "refs/heads/feat"), "the branch must still exist")
    }

    // MARK: F2 - worktree prune is repo wide

    /// Removing one missing-folder worktree runs `git worktree prune`, which also drops every OTHER
    /// missing-folder registration (an unmounted drive, a renamed folder), orphaning a detached HEAD.
    func testRemovingOneMissingWorktreeLeavesOtherRegistrationsAlone() async throws {
        let repo = try baseRepo()
        let awayHome = repo.sandbox.appendingPathComponent("wtA")
        try repo.git("worktree", "add", "--detach", awayHome.path)
        let onlyCopy = try repo.commit("only copy of this work", files: ["w.txt": "w"], in: awayHome)
        // Simulate an unmounted drive / renamed folder.
        let away = repo.sandbox.appendingPathComponent("wtA-moved")
        try FileManager.default.moveItem(at: awayHome, to: away)

        try repo.git("checkout", "-b", "done")
        try repo.commit("done work", files: ["done.txt": "d"])
        try repo.git("checkout", "main")
        try repo.git("merge", "--no-ff", "-m", "merge done", "done")
        let wtB = repo.sandbox.appendingPathComponent("wtB")
        try repo.git("worktree", "add", wtB.path, "done")
        try FileManager.default.removeItem(at: wtB)

        let (cleaner, _) = makeCleaner(repo)
        let outcome = await cleaner.removeWorktree(repoRoot: repo.root, path: wtB, approved: .safe)
        guard case .removed = outcome else { return XCTFail("\(outcome)") }

        let listed = try repo.git("worktree", "list", "--porcelain")
        XCTAssertTrue(listed.contains("wtA"), "the unrelated registration for wtA was pruned:\n\(listed)")
        // The commit lives in worktree A's own HEAD, not in a ref. Removing B must leave that registration, and so the
        // commit, exactly as it was.
        let registrationHead = try String(
            contentsOf: repo.root.appendingPathComponent(".git/worktrees/wtA/HEAD"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(registrationHead, onlyCopy, "worktree A's registration was changed")
    }

    func testPruneRegistrationsDoesNotOrphanDetachedCommits() async throws {
        let repo = try baseRepo()
        let home = repo.sandbox.appendingPathComponent("wtA")
        try repo.git("worktree", "add", "--detach", home.path)
        let onlyCopy = try repo.commit("only copy", files: ["w.txt": "w"], in: home)
        try FileManager.default.moveItem(at: home, to: repo.sandbox.appendingPathComponent("wtA-moved"))
        let (cleaner, _) = makeCleaner(repo)
        try await cleaner.pruneWorktreeRegistrations(repoRoot: repo.root)
        let holders = try repo.git("for-each-ref", "--contains", onlyCopy)
        XCTAssertFalse(holders.isEmpty, "documented as 'loses nothing' but commit \(onlyCopy.prefix(8)) is orphaned")
    }

    // MARK: F3 - active agent worktree swept up by `clean --include-review`

    func testActiveAgentWorktreeIsNotRemovedByIncludeReviewPath() async throws {
        let repo = try baseRepo()
        try repo.addOrigin()
        let agentDir = repo.root.appendingPathComponent(".claude/worktrees/agent1")
        try FileManager.default.createDirectory(
            at: agentDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try repo.git("worktree", "add", "-b", "worktree-agent1", agentDir.path)
        try repo.commit("agent is mid task", files: ["x.txt": "x"], in: agentDir)  // clean tree, unmerged commit

        let log = repo.sandbox.appendingPathComponent("undo.jsonl")
        let workspace = Workspace(
            settings: Settings(roots: [repo.sandbox], scanDepth: 3), prProvider: nil, undoLog: UndoLog(url: log))
        let scan = await workspace.scan()
        let row = try XCTUnwrap(scan.rows.first { $0.kind == .worktree })
        XCTAssertEqual(row.agent?.state, .active)
        XCTAssertEqual(row.verdict, .review)
        // Exactly the predicate in CleanCommand with --include-review:
        let includeReview = true
        let chosen = [row].filter { $0.isBulkEligible || (includeReview && $0.verdict == .review && $0.isSelectable) }

        for await _ in workspace.clean(chosen) {}
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: agentDir.path),
            "the folder of an agent that is still working (state active) was removed")
    }

    // MARK: F4 - inherited GIT_DIR redirects every git call

    func testInheritedGitDirDoesNotRedirectTheEngine() async throws {
        let a = try baseRepo()
        let b = try baseRepo()
        try b.git("branch", "marker-b")
        setenv("GIT_DIR", a.root.appendingPathComponent(".git").path, 1)
        defer { unsetenv("GIT_DIR") }
        let out = try await GitRunner().runChecked(["rev-parse", "--absolute-git-dir"], in: b.root)
        unsetenv("GIT_DIR")
        XCTAssertEqual(URL(fileURLWithPath: out).canonicalized.path, b.root.appendingPathComponent(".git").path)
    }

    // MARK: F5 - tampered or corrupt undo record deletes arbitrary refs

    func testExpireTrashOnlyTouchesRefsUnderTrashNamespace() async throws {
        let repo = try baseRepo()
        try repo.git("branch", "precious")
        let (cleaner, log) = makeCleaner(repo)
        let record = UndoRecord(
            timestamp: Date(timeIntervalSinceNow: -90 * 86_400), repoPath: repo.root.path,
            action: .deleteBranch, branch: "x", tip: try repo.sha("main"), upstream: nil, worktreePath: nil,
            trashRef: "refs/heads/precious", status: .completed)
        try await log.append(record)
        await cleaner.expireTrash(retentionDays: 30)
        XCTAssertTrue(refExists(repo, "refs/heads/precious"), "expireTrash deleted a ref outside refs/lopper/trash")
    }

    // MARK: F6 - branch being rebased in another worktree

    func testBranchBeingRebasedInAnotherWorktreeIsNotDeleted() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "other")
        try repo.commit("other", files: ["o.txt": "o"])
        try repo.git("checkout", "main")
        try repo.git("checkout", "-b", "topic")
        try repo.commit("t1", files: ["t1.txt": "1"])
        try repo.commit("t2", files: ["t2.txt": "2"])
        try repo.git("checkout", "main")
        // Squash merge: topic's content is on main, topic is not an ancestor.
        try repo.git("merge", "--squash", "topic")
        try repo.git("commit", "-m", "squash topic")
        let wt = repo.sandbox.appendingPathComponent("wt")
        try repo.git("worktree", "add", wt.path, "topic")
        setenv("GIT_SEQUENCE_EDITOR", "sed -i '' 's/^pick/edit/'", 1)
        defer { unsetenv("GIT_SEQUENCE_EDITOR") }
        try repo.git("rebase", "-i", "other", in: wt)
        unsetenv("GIT_SEQUENCE_EDITOR")
        let state = try repo.git("status", "--short", "--branch", in: wt)
        XCTAssertTrue(state.contains("HEAD (no branch)"), state)
        let held = try repo.git("for-each-ref", "--format=%(worktreepath)", "refs/heads/topic")

        let entry = try await RepoInspector().inspectBranch(repoRoot: repo.root, name: "topic")
        let (cleaner, _) = makeCleaner(repo)
        let outcome = await cleaner.deleteBranch(repoRoot: repo.root, name: "topic", approved: .safe)
        XCTAssertTrue(
            refExists(repo, "refs/heads/topic"),
            "worktreepath='\(held)' verdict=\(String(describing: entry?.verdict.kind)) outcome=\(outcome)")
    }
}
