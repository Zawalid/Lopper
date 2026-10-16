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

    /// A linked worktree made by Claude Code. `kind` and `evidence` must be consistent, as the real
    /// classifier would produce them.
    static func agentWorktree(
        _ name: String, kind: VerdictKind = .safe, evidence: MergeEvidence = .ancestorOfDefault,
        ahead: Int = 0, daysAgo: Double = 5, detached: Bool = false, dirty: Bool = false,
        extraFiles: [String] = [], locked: Bool = false, root: URL = Fixtures.root
    ) -> WorktreeEntry {
        var reasons: [VerdictReason] = []
        switch kind {
        case .safe:
            reasons = [.mergedVia(evidence)]
        case .review:
            if !evidence.isStrong { reasons.append(.noMergeEvidence) }
            if dirty { reasons.append(.worktreeDirty) }
            if locked { reasons.append(.worktreeLocked) }
            if !extraFiles.isEmpty { reasons.append(.worktreeHasExtraFiles(extraFiles)) }
        case .protected:
            reasons = [.matchesProtectedPattern("release/*")]
        }
        return WorktreeEntry(
            repoRoot: root, path: root.appendingPathComponent(".claude/worktrees/\(name)"),
            head: "0123456789abcdef", branch: detached ? nil : "claude/\(name)", isMain: false,
            isLocked: locked, isPrunable: false,
            status: WorktreeStatus(isDirty: dirty, extraFiles: extraFiles, disposablePaths: []),
            operationInProgress: false, evidence: evidence,
            verdict: Verdict(kind: kind, reasons: reasons, evidence: evidence),
            agentHint: "Claude Code", ahead: ahead,
            lastCommit: now.addingTimeInterval(-daysAgo * 86_400),
            createdAt: now.addingTimeInterval(-(daysAgo + 2) * 86_400))
    }

    /// Nine agent worktrees covering every state: two finished, one just touched, two not merged (one with
    /// uncommitted work), two abandoned (one detached), one finished but locked, one protected.
    static var agentSample: RepoSnapshot {
        snapshot(
            branches: [branch("main", .protected)],
            worktrees: [
                agentWorktree("finished-a", daysAgo: 6),
                agentWorktree("finished-b", daysAgo: 12),
                agentWorktree("just-now", daysAgo: 0.005),
                agentWorktree("wip", kind: .review, evidence: .none, ahead: 3, daysAgo: 9),
                agentWorktree("scratch", kind: .review, evidence: .none, daysAgo: 20, dirty: true),
                agentWorktree("old-feature", kind: .review, evidence: .none, ahead: 2, daysAgo: 45),
                agentWorktree("old-detached", kind: .review, evidence: .none, ahead: 1, daysAgo: 40, detached: true),
                agentWorktree("locked-done", kind: .review, evidence: .ancestorOfDefault, daysAgo: 20, locked: true),
                agentWorktree("release", kind: .protected, daysAgo: 3),
            ])
    }

    /// Sizes and last activity for every agent worktree of `agentSample`, as the measuring step would
    /// have produced them.
    static var agentMeasurements: (sizes: [String: Int64], activity: [String: Date]) {
        var sizes: [String: Int64] = [:]
        var activity: [String: Date] = [:]
        for (index, entry) in agentSample.worktrees.filter({ !$0.isMain }).enumerated() {
            sizes[entry.path.path] = Int64(180_000_000 + index * 95_000_000)
            activity[entry.path.path] = entry.lastCommit
        }
        return (sizes, activity)
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

    static var folderSuggestions: [FolderSuggestion] {
        [
            FolderSuggestion(path: URL(fileURLWithPath: "/Users/me/Developer"), repoCount: 14),
            FolderSuggestion(path: URL(fileURLWithPath: "/Users/me/Projects"), repoCount: 9),
            FolderSuggestion(path: URL(fileURLWithPath: "/Users/me/Documents/GitHub"), repoCount: 3),
            FolderSuggestion(path: URL(fileURLWithPath: "/Users/me/Code"), repoCount: 0),
        ]
    }

    /// Tool caches for previews, outside any repository.
    static var developerCaches: [DiskArtifact] {
        let home = URL(fileURLWithPath: "/Users/me")
        func cache(_ name: String, _ relative: String, _ bytes: Int64, _ how: String) -> DiskArtifact {
            let url = home.appendingPathComponent(relative)
            return DiskArtifact(
                path: url, name: name, kind: .cache, bytes: bytes, newestModification: now,
                projectDirectory: url.deletingLastPathComponent(), checkoutRoot: home,
                repoRoot: URL(fileURLWithPath: DeveloperCaches.historyRepoPath), location: .developerCache,
                removal: .offered(regenerate: how))
        }
        return [
            cache("Xcode build data", "Library/Developer/Xcode/DerivedData", 6_200_000_000, "your next Xcode build"),
            cache("npm cache", ".npm/_cacache", 1_900_000_000, "the next npm install"),
        ]
    }

    /// Generated folders for previews: a big install and a build output in the main folder, one more in a worktree.
    static var diskArtifacts: [DiskArtifact] {
        func artifact(
            _ name: String, _ bytes: Int64, kind: ArtifactKind, in checkout: String,
            location: ArtifactLocation, removal: ArtifactRemoval
        ) -> DiskArtifact {
            let root = URL(fileURLWithPath: checkout)
            return DiskArtifact(
                path: root.appendingPathComponent(name), name: name, kind: kind, bytes: bytes,
                newestModification: now.addingTimeInterval(-86_400), projectDirectory: root, checkoutRoot: root,
                repoRoot: Fixtures.root, location: location, removal: removal)
        }
        return [
            artifact("node_modules", 1_450_000_000, kind: .packages, in: "/code/api", location: .mainCheckout,
                     removal: .offered(regenerate: "npm ci")),
            artifact(".next", 310_000_000, kind: .frameworkCache, in: "/code/api", location: .mainCheckout,
                     removal: .offered(regenerate: "your next build or dev run")),
            artifact("build", 90_000_000, kind: .buildOutput, in: "/code/api", location: .mainCheckout,
                     removal: .blocked(reason: "Lopper cannot tell how this folder is rebuilt.")),
            artifact("node_modules", 820_000_000, kind: .packages, in: "/code/wt/feat/in-worktree",
                     location: .worktree(branch: "feat/in-worktree"), removal: .offered(regenerate: "pnpm install")),
        ]
    }
}
#endif
