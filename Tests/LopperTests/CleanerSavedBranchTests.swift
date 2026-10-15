import XCTest
@testable import Lopper

final class CleanerSavedBranchTests: XCTestCase {
    private func baseRepo() throws -> TestRepo {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n"])
        return repo
    }

    private func makeCleaner(_ repo: TestRepo) -> Cleaner {
        Cleaner(
            inspector: RepoInspector(),
            undoLog: UndoLog(url: repo.sandbox.appendingPathComponent("undo-log.jsonl")))
    }

    private func branchExists(_ repo: TestRepo, _ name: String) -> Bool {
        (try? repo.git("rev-parse", "--verify", "--quiet", "refs/heads/\(name)")) != nil
    }

    func testDetachedUnmergedWorktreeIsSavedAsABranchBeforeRemoval() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt détaché")
        try repo.git("worktree", "add", "--detach", wt.path)
        let tip = try repo.commit("only copy", files: ["w.txt": "w"], in: wt)

        let outcome = await makeCleaner(repo).removeWorktree(repoRoot: repo.root, path: wt, approved: .review)

        guard case .removed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path))
        let name = Cleaner.savedBranchName(forWorktreeAt: wt, head: tip)
        XCTAssertEqual(try repo.sha("refs/heads/\(name)"), tip)
    }

    func testRefusedRemovalLeavesNoSavedBranch() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-dirty-detached")
        try repo.git("worktree", "add", "--detach", wt.path)
        let tip = try repo.commit("only copy", files: ["w.txt": "w"], in: wt)
        try "precious".write(to: wt.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)

        let outcome = await makeCleaner(repo).removeWorktree(repoRoot: repo.root, path: wt, approved: .review)

        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try String(contentsOf: wt.appendingPathComponent("app.txt"), encoding: .utf8), "precious")
        XCTAssertFalse(branchExists(repo, Cleaner.savedBranchName(forWorktreeAt: wt, head: tip)))
    }

    func testMergedDetachedWorktreeGetsNoSavedBranch() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-merged-detached")
        try repo.git("worktree", "add", "--detach", wt.path)

        let outcome = await makeCleaner(repo).removeWorktree(repoRoot: repo.root, path: wt, approved: .safe)

        guard case .removed = outcome else { return XCTFail("\(outcome)") }
        let saved = try repo.git("for-each-ref", "--format=%(refname)", "refs/heads/lopper")
        XCTAssertEqual(saved, "")
    }

    func testWorktreeWithABranchNeverGetsASavedBranch() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-branch")
        try repo.git("worktree", "add", "-b", "feature", wt.path)
        try repo.commit("work", files: ["f.txt": "f"], in: wt)

        let outcome = await makeCleaner(repo).removeWorktree(repoRoot: repo.root, path: wt, approved: .review)

        guard case .removed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(branchExists(repo, "feature"))
        XCTAssertEqual(try repo.git("for-each-ref", "--format=%(refname)", "refs/heads/lopper"), "")
    }
}
