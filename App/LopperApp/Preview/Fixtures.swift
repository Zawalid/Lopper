#if DEBUG
// Sample data for previews and tests. Compiled into debug builds only.
import Foundation
import Lopper

enum Fixtures {
    static let root = URL(fileURLWithPath: "/code/api")
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func verdict(_ kind: VerdictKind, _ evidence: MergeEvidence = .ancestorOfDefault) -> Verdict {
        switch kind {
        case .safe: Verdict(kind: .safe, reasons: [.mergedVia(evidence)], evidence: evidence)
        case .review: Verdict(kind: .review, reasons: [.noMergeEvidence], evidence: .none)
        case .protected: Verdict(kind: .protected, reasons: [.isDefaultBranch], evidence: evidence)
        }
    }

    static func branch(
        _ name: String, _ kind: VerdictKind, root: URL = Fixtures.root, ageDays: Int = 10,
        checkedOutAt: URL? = nil, evidence: MergeEvidence = .ancestorOfDefault
    ) -> BranchEntry {
        // A Review item has no merge evidence by definition; keep the entry consistent with its verdict.
        let effective: MergeEvidence = kind == .review ? .none : evidence
        return BranchEntry(
            repoRoot: root, name: name, tip: "abc", upstream: nil,
            lastCommit: now.addingTimeInterval(-Double(ageDays) * 86_400), ahead: 0, behind: 0,
            checkedOutAt: checkedOutAt, evidence: effective, verdict: verdict(kind, effective))
    }

    static func worktree(
        _ branchName: String?, _ kind: VerdictKind, root: URL = Fixtures.root, isMain: Bool = false,
        extraFiles: [String] = [], evidence: MergeEvidence = .ancestorOfDefault
    ) -> WorktreeEntry {
        let path = isMain ? root : URL(fileURLWithPath: "/code/wt/\(branchName ?? "detached")")
        let evidence: MergeEvidence = kind == .review ? .none : evidence
        return WorktreeEntry(
            repoRoot: root, path: path, head: "abc", branch: branchName, isMain: isMain,
            isLocked: false, isPrunable: false,
            status: WorktreeStatus(isDirty: false, extraFiles: extraFiles, disposablePaths: []),
            operationInProgress: false, evidence: evidence, verdict: verdict(kind, evidence),
            agentHint: nil)
    }

    static func snapshot(
        name: String = "api", root: URL = Fixtures.root,
        branches: [BranchEntry], worktrees: [WorktreeEntry] = [], remote: String? = "git@github.com:acme/api.git"
    ) -> RepoSnapshot {
        RepoSnapshot(
            repo: Repo(root: root, name: name, defaultBranch: "main", remoteURL: remote),
            branches: branches,
            worktrees: [worktree("main", .protected, root: root, isMain: true)] + worktrees,
            prDetectionAvailable: true, scannedAt: now)
    }

    static var historyRecords: [UndoRecord] {
        let batch = UUID()
        let earlier = UUID()
        func record(_ branch: String, _ action: UndoAction, batch: UUID, hoursAgo: Double, status: UndoStatus = .completed) -> UndoRecord {
            UndoRecord(
                timestamp: Date().addingTimeInterval(-hoursAgo * 3_600), repoPath: root.path, action: action,
                branch: branch, tip: "abc1234", upstream: nil,
                worktreePath: action == .removeWorktree ? "/code/wt/\(branch)" : nil,
                trashRef: "refs/lopper/trash/1/\(branch)", status: status, batchID: batch)
        }
        return [
            record("feat/old-1", .deleteBranch, batch: batch, hoursAgo: 2),
            record("feat/old-2", .deleteBranch, batch: batch, hoursAgo: 2),
            record("feat/in-worktree", .removeWorktree, batch: batch, hoursAgo: 2),
            record("fix/typo", .deleteBranch, batch: earlier, hoursAgo: 50, status: .restored),
            record("chore/ci", .deleteBranch, batch: earlier, hoursAgo: 50),
        ]
    }

    /// 3 safe branches, 1 safe worktree (with its branch), 1 review branch, 1 protected default branch.
    static var sample: RepoSnapshot {
        snapshot(
            branches: [
                branch("main", .protected),
                branch("feat/old-1", .safe, ageDays: 60, evidence: .prMerged(number: 12)),
                branch("feat/old-2", .safe, ageDays: 40),
                branch("fix/old-3", .safe, ageDays: 20),
                branch("wip/unmerged", .review, ageDays: 5),
                branch("feat/in-worktree", .protected, checkedOutAt: URL(fileURLWithPath: "/code/wt/feat/in-worktree")),
            ],
            worktrees: [worktree("feat/in-worktree", .safe, evidence: .contentIncluded)])
    }
}
#endif
