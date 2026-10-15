import XCTest
import Lopper  // not @testable: this test is about the public API

final class SnapshotConstructionTests: XCTestCase {
    func testSnapshotTypesCanBeBuiltOutsideTheEngineForFixturesAndFakes() {
        let root = URL(fileURLWithPath: "/code/api")
        let verdict = Verdict(kind: .safe, reasons: [.mergedVia(.ancestorOfDefault)], evidence: .ancestorOfDefault)
        let branch = BranchEntry(
            repoRoot: root, name: "feat/x", tip: "abc", upstream: nil, lastCommit: Date(timeIntervalSince1970: 0),
            ahead: 0, behind: 2, checkedOutAt: nil, evidence: .ancestorOfDefault, verdict: verdict)
        let worktree = WorktreeEntry(
            repoRoot: root, path: root, head: "abc", branch: "main", isMain: true, isLocked: false,
            isPrunable: false, status: WorktreeStatus(), operationInProgress: false,
            evidence: .none, verdict: verdict, agentHint: nil)
        let snapshot = RepoSnapshot(
            repo: Repo(root: root, name: "api", defaultBranch: "main", remoteURL: nil),
            branches: [branch], worktrees: [worktree], prDetectionAvailable: true,
            scannedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(branch.id, "/code/api#feat/x")
        XCTAssertEqual(worktree.id, "/code/api")
        XCTAssertEqual(snapshot.repo.id, "/code/api")
        XCTAssertEqual(snapshot.branches.count, 1)
    }
}
