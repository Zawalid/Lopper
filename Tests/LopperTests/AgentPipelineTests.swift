import XCTest
@testable import Lopper

final class AgentPipelineTests: XCTestCase {
    /// Worktrees live under `<sandbox>/.claude/worktrees` (outside the repository, so `git add -A` in the
    /// main working directory never sees them) and match the Claude Code path convention.
    private func worktreesDirectory(_ repo: TestRepo) -> URL {
        repo.sandbox.appendingPathComponent(".claude/worktrees", isDirectory: true)
    }

    func testOnlyFinishedWorktreesAreReclaimedAndEverythingElseSurvives() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n", ".gitignore": "node_modules\n.env.local\n"])
        let dir = worktreesDirectory(repo)

        // finished: merged with a merge commit, has a node_modules folder.
        let finished = dir.appendingPathComponent("finished")
        try repo.git("worktree", "add", "-b", "claude/finished", finished.path)
        try repo.commit("done", files: ["d.txt": "d"], in: finished)
        try repo.git("merge", "--no-ff", "-m", "merge finished", "claude/finished")
        try FileManager.default.createDirectory(
            at: finished.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try "x".write(
            to: finished.appendingPathComponent("node_modules/pkg/i.js"), atomically: true, encoding: .utf8)

        // unmerged, fully committed.
        let committed = dir.appendingPathComponent("committed")
        try repo.git("worktree", "add", "-b", "claude/committed", committed.path)
        try repo.commit("wip", files: ["c.txt": "c"], in: committed)

        // dirty: merged branch, uncommitted edit.
        let dirty = dir.appendingPathComponent("dirty")
        try repo.git("worktree", "add", "-b", "claude/dirty", dirty.path)
        try "precious".write(to: dirty.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)

        // env: merged branch holding a gitignored secret.
        let env = dir.appendingPathComponent("env")
        try repo.git("worktree", "add", "-b", "claude/env", env.path)
        try "SECRET=1".write(to: env.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)

        // detached with its own commit.
        let detached = dir.appendingPathComponent("detached")
        try repo.git("worktree", "add", "--detach", detached.path)
        try repo.commit("only copy", files: ["x.txt": "x"], in: detached)

        let snapshot = try await RepoInspector().inspect(repoRoot: repo.root)
        let disposable = Set(Settings.defaultDisposableNames)
        let later = Date().addingTimeInterval(86_400)  // a day on: every worktree is idle
        var assessments: [String: (WorktreeEntry, AgentAssessment)] = [:]
        for worktree in snapshot.worktrees where !worktree.isMain {
            let usage = await SizeCalculator.measure(worktree.path, disposableNames: disposable)
            let assessment = try XCTUnwrap(AgentAssessor.assess(
                worktree: worktree, usage: usage, policy: AgentPolicy(), now: later))
            assessments[worktree.path.lastPathComponent] = (worktree, assessment)
        }

        XCTAssertEqual(assessments["finished"]?.1.state, .finished)
        XCTAssertEqual(assessments["committed"]?.1.state, .unmerged)
        XCTAssertEqual(assessments["committed"]?.1.removal, .keepBranch("claude/committed"))
        XCTAssertEqual(assessments["dirty"]?.1.state, .unmerged)
        XCTAssertEqual(assessments["env"]?.1.state, .unmerged)
        XCTAssertEqual(assessments["detached"]?.1.state, .unmerged)
        let reclaimable = assessments.filter { $0.value.1.isReclaimable }.map(\.key)
        XCTAssertEqual(reclaimable, ["finished"])

        // Run exactly what "Reclaim finished" would send.
        let cleaner = Cleaner(
            inspector: RepoInspector(),
            undoLog: UndoLog(url: repo.sandbox.appendingPathComponent("undo-log.jsonl")))
        let items = assessments.values.filter { $0.1.isReclaimable }.map { entry, _ in
            CleanupItem.worktree(
                repoRoot: repo.root, path: entry.path, approved: .safe, deleteBranch: entry.branch)
        }
        for await _ in BatchCleaner(cleaner: cleaner).run(items: items) {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: finished.path))
        for survivor in [committed, dirty, env, detached] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: survivor.path), survivor.lastPathComponent)
        }
        XCTAssertEqual(
            try String(contentsOf: dirty.appendingPathComponent("app.txt"), encoding: .utf8), "precious")
        XCTAssertEqual(
            try String(contentsOf: env.appendingPathComponent(".env.local"), encoding: .utf8), "SECRET=1")
    }

    func testAgeFromTheClockAndAbandonedAfterStaleDays() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n"])
        let wt = worktreesDirectory(repo).appendingPathComponent("old")
        try repo.git("worktree", "add", "-b", "claude/old", wt.path)
        try repo.commit("wip", files: ["o.txt": "o"], in: wt)

        let snapshot = try await RepoInspector().inspect(repoRoot: repo.root)
        let entry = try XCTUnwrap(snapshot.worktrees.first { !$0.isMain })
        let usage = await SizeCalculator.measure(entry.path, disposableNames: [])

        let soon = AgentAssessor.assess(
            worktree: entry, usage: usage, policy: AgentPolicy(), now: Date().addingTimeInterval(5 * 86_400))
        let longAfter = AgentAssessor.assess(
            worktree: entry, usage: usage, policy: AgentPolicy(), now: Date().addingTimeInterval(40 * 86_400))

        XCTAssertEqual(soon?.state, .unmerged)
        XCTAssertEqual(longAfter?.state, .abandoned)
        XCTAssertEqual(longAfter?.isReviewReclaimable, true)
    }
}
