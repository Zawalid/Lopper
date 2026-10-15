import Foundation
import Lopper

/// One line in the workbench: a branch, or a worktree (which carries its branch with it).
struct CleanupRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case branch, worktree }

    let id: String
    let kind: Kind
    let repoRoot: URL
    let repoName: String
    let title: String
    /// Folder for worktrees, "Local branch" for branches.
    let location: String
    let path: URL?
    let verdict: VerdictKind
    let reasons: [String]
    let evidence: String
    let prNumber: Int?
    let prURL: URL?
    let lastCommit: Date?
    let size: Int64?
    let agentHint: String?
    let extraFiles: [String]
    /// The branch removed together with a Safe worktree.
    let bundledBranch: String?
    /// The Agents page's reading of this worktree; nil unless a known tool made it.
    var agent: AgentAssessment? = nil

    var isSelectable: Bool { verdict != .protected }
    var lastCommitSort: Date { lastCommit ?? .distantPast }
    var sizeSort: Int64 { size ?? -1 }

    /// What the engine should do for this row, or nil for Protected rows.
    var cleanupItem: CleanupItem? {
        guard isSelectable else { return nil }
        switch kind {
        case .branch:
            return .branch(repoRoot: repoRoot, name: title, approved: verdict)
        case .worktree:
            guard let path else { return nil }
            return .worktree(repoRoot: repoRoot, path: path, approved: verdict, deleteBranch: bundledBranch)
        }
    }
}

enum RowMapper {
    /// Branches checked out in a linked worktree are represented by that worktree's row; the main
    /// working directory is the repository itself and gets no row.
    static func rows(
        for snapshot: RepoSnapshot, sizes: [String: DiskUsage],
        policy: AgentPolicy = AgentPolicy(), now: Date = Date()
    ) -> [CleanupRow] {
        let repo = snapshot.repo
        var rows: [CleanupRow] = []

        for worktree in snapshot.worktrees where !worktree.isMain {
            let title = worktree.branch ?? worktree.path.lastPathComponent
            rows.append(CleanupRow(
                id: "worktree:\(worktree.path.path)",
                kind: .worktree,
                repoRoot: repo.root,
                repoName: repo.name,
                title: title,
                location: abbreviated(worktree.path),
                path: worktree.path,
                verdict: worktree.verdict.kind,
                reasons: worktree.verdict.reasons.map(\.text),
                evidence: worktree.evidence.summary,
                prNumber: prNumber(worktree.evidence),
                prURL: prNumber(worktree.evidence).flatMap {
                    PullRequestLink.url(remoteURL: repo.remoteURL, number: $0)
                },
                lastCommit: snapshot.branches.first { $0.name == worktree.branch }?.lastCommit,
                size: sizes[worktree.path.path]?.total,
                agentHint: worktree.agentHint,
                extraFiles: worktree.status.extraFiles,
                bundledBranch: worktree.verdict.kind == .safe ? worktree.branch : nil,
                agent: AgentAssessor.assess(
                    worktree: worktree, usage: sizes[worktree.path.path], policy: policy, now: now)))
        }

        for branch in snapshot.branches where branch.checkedOutAt == nil {
            rows.append(CleanupRow(
                id: "branch:\(repo.root.path)#\(branch.name)",
                kind: .branch,
                repoRoot: repo.root,
                repoName: repo.name,
                title: branch.name,
                location: "Local branch",
                path: nil,
                verdict: branch.verdict.kind,
                reasons: branch.verdict.reasons.map(\.text),
                evidence: branch.evidence.summary,
                prNumber: prNumber(branch.evidence),
                prURL: prNumber(branch.evidence).flatMap {
                    PullRequestLink.url(remoteURL: repo.remoteURL, number: $0)
                },
                lastCommit: branch.lastCommit,
                size: nil,
                agentHint: nil,
                extraFiles: [],
                bundledBranch: nil))
        }

        return rows.sorted(by: defaultOrder)
    }

    /// Safe first, then Review, then Protected; oldest work first inside each group.
    static func defaultOrder(_ lhs: CleanupRow, _ rhs: CleanupRow) -> Bool {
        if lhs.verdict != rhs.verdict { return lhs.verdict < rhs.verdict }
        if lhs.lastCommitSort != rhs.lastCommitSort { return lhs.lastCommitSort < rhs.lastCommitSort }
        return lhs.title < rhs.title
    }

    static func prNumber(_ evidence: MergeEvidence) -> Int? {
        switch evidence {
        case .prMerged(let number), .prMergedWithNewerCommits(let number): number
        default: nil
        }
    }

    static func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

struct RepoSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let root: URL
    let safeBranches: Int
    let safeWorktrees: Int
    let review: Int
    let protected: Int
    let reclaimableBytes: Int64
    let defaultBranch: String?
    /// Set when the scan of this repository failed.
    let failure: String?

    var safe: Int { safeBranches + safeWorktrees }
    var total: Int { safe + review + protected }
    var hasSafeItems: Bool { safe > 0 }
}
