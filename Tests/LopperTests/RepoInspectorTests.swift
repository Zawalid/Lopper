import XCTest
@testable import Lopper

final class RepoInspectorTests: XCTestCase {
    private struct FakePRProvider: PRProvider {
        var prs: [MergedPR] = []
        var fails = false
        func mergedPullRequests(in repoRoot: URL) async throws -> [MergedPR] {
            if fails { throw CommandError.launchFailed("gh missing") }
            return prs
        }
    }

    private func inspect(_ repo: TestRepo, prs: PRProvider? = nil, settings: Settings = Settings()) async throws -> RepoSnapshot {
        try await RepoInspector(settings: settings, prProvider: prs).inspect(repoRoot: repo.root)
    }

    private func branch(_ snapshot: RepoSnapshot, _ name: String) throws -> BranchEntry {
        try XCTUnwrap(snapshot.branches.first { $0.name == name }, "missing branch \(name)")
    }

    private func worktree(_ snapshot: RepoSnapshot, named last: String) throws -> WorktreeEntry {
        try XCTUnwrap(snapshot.worktrees.first { $0.path.lastPathComponent == last }, "missing worktree \(last)")
    }

    private func baseRepo() throws -> TestRepo {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n", ".gitignore": "node_modules\n.env.local\n"])
        return repo
    }

    func testBranchesAreClassifiedAcrossMergeStyles() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "merged")
        try repo.commit("m", files: ["m.txt": "m"])
        try repo.git("checkout", "main")
        try repo.git("merge", "--no-ff", "-m", "merge merged", "merged")

        try repo.git("checkout", "-b", "squashed")
        try repo.commit("s1", files: ["s1.txt": "1"])
        try repo.commit("s2", files: ["s2.txt": "2"])
        try repo.git("checkout", "main")
        try repo.git("merge", "--squash", "squashed")
        try repo.git("commit", "-m", "squashed (#2)")

        try repo.git("checkout", "-b", "wip")
        try repo.commit("w", files: ["w.txt": "w"])
        try repo.git("checkout", "main")

        let snapshot = try await inspect(repo)
        XCTAssertEqual(snapshot.repo.defaultBranch, "main")
        XCTAssertEqual(try branch(snapshot, "main").verdict.kind, .protected)
        XCTAssertEqual(try branch(snapshot, "merged").verdict.kind, .safe)
        XCTAssertEqual(try branch(snapshot, "merged").evidence, .ancestorOfDefault)
        XCTAssertEqual(try branch(snapshot, "squashed").verdict.kind, .safe)
        XCTAssertEqual(try branch(snapshot, "squashed").evidence, .contentIncluded)
        XCTAssertEqual(try branch(snapshot, "wip").verdict.kind, .review)
        XCTAssertEqual(try branch(snapshot, "wip").ahead, 1)
    }

    func testUpstreamGoneBranchIsReviewNotSafe() async throws {
        let repo = try baseRepo()
        try repo.addOrigin()
        try repo.git("checkout", "-b", "closed-pr")
        try repo.commit("work", files: ["c.txt": "c"])
        try repo.git("push", "-u", "origin", "closed-pr")
        try repo.git("checkout", "main")
        try repo.git("push", "origin", "--delete", "closed-pr")
        try repo.git("fetch", "--prune")

        let entry = try branch(try await inspect(repo), "closed-pr")
        XCTAssertEqual(entry.evidence, .upstreamGone)
        XCTAssertEqual(entry.verdict.kind, .review)
    }

    func testPrProviderUpgradesSquashedBranchWithLaterEditsToSafe() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "feature")
        try repo.commit("one", files: ["app.txt": "F1\n"])
        let tip = try repo.commit("two", files: ["app.txt": "F1\nF2\n"])
        try repo.git("checkout", "main")
        try repo.git("merge", "--squash", "feature")
        try repo.git("commit", "-m", "feature (#9)")
        try repo.commit("later", files: ["app.txt": "LATER\nF2\n"])

        let without = try await inspect(repo)
        XCTAssertEqual(try branch(without, "feature").verdict.kind, .review)

        let provider = FakePRProvider(prs: [MergedPR(number: 9, headBranch: "feature", headSHA: tip, baseBranch: "main")])
        let with = try await inspect(repo, prs: provider)
        XCTAssertTrue(with.prDetectionAvailable)
        XCTAssertEqual(try branch(with, "feature").evidence, .prMerged(number: 9))
        XCTAssertEqual(try branch(with, "feature").verdict.kind, .safe)
    }

    func testFailingPrProviderDegradesGracefully() async throws {
        let repo = try baseRepo()
        let snapshot = try await inspect(repo, prs: FakePRProvider(fails: true))
        XCTAssertFalse(snapshot.prDetectionAvailable)
        XCTAssertEqual(try branch(snapshot, "main").verdict.kind, .protected)
    }

    func testBranchCheckedOutInLinkedWorktreeIsProtectedAndLinked() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-feature")
        try repo.git("worktree", "add", "-b", "feature", wt.path)

        let snapshot = try await inspect(repo)
        let entry = try branch(snapshot, "feature")
        XCTAssertEqual(entry.verdict.kind, .protected)
        XCTAssertEqual(entry.checkedOutAt?.path, wt.path)
    }

    func testCleanMergedWorktreeIsSafeAndIgnoresNodeModules() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-done")
        try repo.git("worktree", "add", "-b", "done", wt.path)
        try repo.commit("work", files: ["d.txt": "d"], in: wt)
        try repo.git("merge", "--no-ff", "-m", "merge done", "done")
        try FileManager.default.createDirectory(
            at: wt.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try "x".write(to: wt.appendingPathComponent("node_modules/pkg/index.js"), atomically: true, encoding: .utf8)

        let entry = try worktree(try await inspect(repo), named: "wt-done")
        XCTAssertEqual(entry.verdict.kind, .safe)
        XCTAssertEqual(entry.status.disposablePaths, ["node_modules/"])
        XCTAssertTrue(entry.status.extraFiles.isEmpty)
    }

    func testWorktreeWithEnvFileIsReview() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-env")
        try repo.git("worktree", "add", "-b", "env", wt.path)
        try "SECRET=1".write(to: wt.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)

        let entry = try worktree(try await inspect(repo), named: "wt-env")
        XCTAssertEqual(entry.verdict.kind, .review)
        XCTAssertTrue(entry.verdict.reasons.contains(.worktreeHasExtraFiles([".env.local"])))
    }

    func testDirtyWorktreeIsReview() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-dirty")
        try repo.git("worktree", "add", "-b", "dirty", wt.path)
        try "changed".write(to: wt.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)

        let entry = try worktree(try await inspect(repo), named: "wt-dirty")
        XCTAssertEqual(entry.verdict.kind, .review)
        XCTAssertTrue(entry.status.isDirty)
    }

    func testLockedWorktreeIsReview() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-locked")
        try repo.git("worktree", "add", "-b", "locked", wt.path)
        try repo.git("worktree", "lock", "--reason", "agent running", wt.path)

        let entry = try worktree(try await inspect(repo), named: "wt-locked")
        XCTAssertTrue(entry.isLocked)
        XCTAssertEqual(entry.verdict.kind, .review)
    }

    func testDetachedWorktreeAtMergedCommitIsSafe() async throws {
        let repo = try baseRepo()
        let old = try repo.sha("HEAD")
        try repo.commit("main moves", files: ["n.txt": "n"])
        let wt = repo.sandbox.appendingPathComponent("wt-detached")
        try repo.git("worktree", "add", "--detach", wt.path, old)

        let entry = try worktree(try await inspect(repo), named: "wt-detached")
        XCTAssertNil(entry.branch)
        XCTAssertEqual(entry.verdict.kind, .safe)
    }

    func testMainWorktreeIsProtected() async throws {
        let repo = try baseRepo()
        let snapshot = try await inspect(repo)
        let entry = try XCTUnwrap(snapshot.worktrees.first)
        XCTAssertTrue(entry.isMain)
        XCTAssertEqual(entry.verdict.kind, .protected)
    }

    func testPrunableWorktreeIsFlagged() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-gone")
        try repo.git("worktree", "add", "-b", "gone", wt.path)
        try FileManager.default.removeItem(at: wt)

        let entry = try worktree(try await inspect(repo), named: "wt-gone")
        XCTAssertTrue(entry.isPrunable)
    }

    func testRebaseInProgressForcesReview() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-rebase")
        try repo.git("worktree", "add", "-b", "rebasing", wt.path)
        let gitDir = try repo.git("rev-parse", "--absolute-git-dir", in: wt)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: gitDir).appendingPathComponent("rebase-merge"),
            withIntermediateDirectories: true)

        let entry = try worktree(try await inspect(repo), named: "wt-rebase")
        XCTAssertTrue(entry.operationInProgress)
        XCTAssertEqual(entry.verdict.kind, .review)
    }

    func testStashOnBranchForcesReview() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "stashed")
        try "dirty".write(to: repo.root.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)
        try repo.git("stash")
        try repo.git("checkout", "main")

        let entry = try branch(try await inspect(repo), "stashed")
        XCTAssertEqual(entry.verdict.kind, .review)
        XCTAssertTrue(entry.verdict.reasons.contains(.hasStash))
    }

    func testAgentHintFromWorktreePathAndBranch() {
        XCTAssertEqual(AgentHint.detect(path: "/code/app/.claude/worktrees/fix-bug", branch: "fix-bug"), "Claude Code")
        XCTAssertEqual(AgentHint.detect(path: "/code/app-wt", branch: "claude/refactor"), "Claude Code")
        XCTAssertEqual(AgentHint.detect(path: "/code/app-wt", branch: "codex/spike"), "Codex")
        XCTAssertNil(AgentHint.detect(path: "/code/app-wt", branch: "feature/login"))
    }

    func testStaleIsBasedOnLastCommitAge() async throws {
        let repo = try TestRepo()
        try repo.commit("old", files: ["a": "a"], date: Date().addingTimeInterval(-60 * 86_400))
        let snapshot = try await inspect(repo)
        let main = try branch(snapshot, "main")
        XCTAssertTrue(main.isStale(now: Date(), staleDays: 30))
        XCTAssertFalse(main.isStale(now: Date(), staleDays: 90))
    }

    // MARK: Review focus

    func testWorktreeThatCannotBeReadIsReviewNeverSafe() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-locked-down")
        try repo.git("worktree", "add", "-b", "locked-down", wt.path)
        // Fully merged and clean, but git cannot enter the folder to prove it.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: wt.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wt.path) }

        let entry = try worktree(try await inspect(repo), named: "wt-locked-down")
        XCTAssertEqual(entry.verdict.kind, .review)
        XCTAssertTrue(entry.verdict.reasons.contains(.worktreeUnreadable))
    }

    func testRepositoryWithNoCommitsIsListedWithoutError() async throws {
        let repo = try TestRepo()   // git init only: HEAD is unborn

        let snapshot = try await inspect(repo)
        XCTAssertTrue(snapshot.branches.isEmpty)
        XCTAssertEqual(snapshot.worktrees.count, 1)
        XCTAssertEqual(snapshot.worktrees[0].verdict.kind, .protected)
    }

    func testPathsWithSpacesAndAccentsAreInspected() async throws {
        let fixture = try TestRepo()
        let root = fixture.sandbox.appendingPathComponent("Mes Projets/mon dépôt")
        try TestRepo.makeStandaloneRepo(at: root)
        let wt = fixture.sandbox.appendingPathComponent("arbre de travail é")
        try TestRepo.runGit(["worktree", "add", "-b", "fonction", wt.path], in: root)
        try "x".write(to: wt.appendingPathComponent("notes de réunion.txt"), atomically: true, encoding: .utf8)

        let snapshot = try await RepoInspector().inspect(repoRoot: root)
        let entry = try worktree(snapshot, named: "arbre de travail é")
        XCTAssertEqual(entry.path.path, wt.path)
        XCTAssertEqual(entry.status.extraFiles, ["notes de réunion.txt"])
        XCTAssertEqual(entry.verdict.kind, .review)
    }

    func testManyBranchesAreInspectedWithinTheTimeBudget() async throws {
        let repo = try baseRepo()
        for index in 0..<60 {
            try repo.git("branch", "merged-\(index)")
        }
        let started = ContinuousClock.now

        let snapshot = try await inspect(repo)

        XCTAssertEqual(snapshot.branches.count, 61)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(30))
    }

    func testPrunableWorktreeThatStillExistsOnDiskIsUnreadable() async throws {
        let repo = try baseRepo()
        let wt = repo.root.appendingPathComponent(".claude/worktrees/nested")
        try FileManager.default.createDirectory(
            at: wt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try repo.git("worktree", "add", "-b", "nested", wt.path)
        // Without its .git file the folder is no longer a worktree. Git reports it prunable, and a
        // `git status` run inside it would silently answer for the enclosing repository instead.
        try FileManager.default.removeItem(at: wt.appendingPathComponent(".git"))

        let snapshot = try await inspect(repo)

        let entry = try worktree(snapshot, named: "nested")
        XCTAssertTrue(entry.isPrunable)
        XCTAssertEqual(entry.verdict.kind, .review)
        XCTAssertTrue(entry.verdict.reasons.contains(.worktreeUnreadable), "\(entry.verdict.reasons)")
    }

    func testDefaultBranchIsNotGuessedFromTheCheckedOutBranch() async throws {
        let repo = try TestRepo()
        try repo.git("branch", "-m", "main", "trunk")   // no main, master or origin: unknowable
        try repo.commit("base", files: ["a": "a"])
        try repo.git("checkout", "-b", "feat/x")
        try repo.commit("feature", files: ["f": "f"])

        let snapshot = try await inspect(repo)

        XCTAssertNil(snapshot.repo.defaultBranch)
        // `trunk` is an ancestor of the checked-out branch, which proves nothing about being merged.
        XCTAssertEqual(try branch(snapshot, "trunk").verdict.kind, .review)
    }

    func testPullRequestMergedIntoAnotherBaseIsNotEvidence() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "stacked")
        let tip = try repo.commit("stacked work", files: ["s.txt": "s"])
        try repo.git("checkout", "main")
        // Merged into an integration branch that was later abandoned: main never received it.
        let provider = FakePRProvider(prs: [
            MergedPR(number: 12, headBranch: "stacked", headSHA: tip, baseBranch: "integration"),
        ])

        let snapshot = try await inspect(repo, prs: provider)

        let entry = try branch(snapshot, "stacked")
        XCTAssertEqual(entry.evidence, .none)
        XCTAssertEqual(entry.verdict.kind, .review)
    }
}
