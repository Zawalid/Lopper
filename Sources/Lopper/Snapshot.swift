import Foundation

public struct Repo: Sendable, Equatable, Identifiable {
    public var id: String { root.path }
    public let root: URL
    public let name: String
    /// Nil when it cannot be determined (no origin/HEAD, no main or master, no override). Everything
    /// in such a repository is classified Review; the user can set it in Settings.
    public let defaultBranch: String?
    public let remoteURL: String?

    public init(root: URL, name: String, defaultBranch: String?, remoteURL: String?) {
        self.root = root
        self.name = name
        self.defaultBranch = defaultBranch
        self.remoteURL = remoteURL
    }
}

public struct BranchEntry: Sendable, Equatable, Identifiable {
    public var id: String { "\(repoRoot.path)#\(name)" }
    public let repoRoot: URL
    public let name: String
    public let tip: String
    public let upstream: String?
    public let lastCommit: Date
    public let ahead: Int
    public let behind: Int
    /// A linked worktree that has this branch checked out, if any.
    public let checkedOutAt: URL?
    public let evidence: MergeEvidence
    public let verdict: Verdict

    public init(
        repoRoot: URL, name: String, tip: String, upstream: String?, lastCommit: Date,
        ahead: Int, behind: Int, checkedOutAt: URL?, evidence: MergeEvidence, verdict: Verdict
    ) {
        self.repoRoot = repoRoot
        self.name = name
        self.tip = tip
        self.upstream = upstream
        self.lastCommit = lastCommit
        self.ahead = ahead
        self.behind = behind
        self.checkedOutAt = checkedOutAt
        self.evidence = evidence
        self.verdict = verdict
    }

    public func isStale(now: Date, staleDays: Int) -> Bool {
        now.timeIntervalSince(lastCommit) > TimeInterval(staleDays) * 86_400
    }
}

public struct WorktreeEntry: Sendable, Equatable, Identifiable {
    public var id: String { path.path }
    public let repoRoot: URL
    public let path: URL
    public let head: String
    public let branch: String?
    public let isMain: Bool
    public let isLocked: Bool
    public let isPrunable: Bool
    public let status: WorktreeStatus
    public let operationInProgress: Bool
    public let evidence: MergeEvidence
    public let verdict: Verdict
    public let agentHint: String?

    public init(
        repoRoot: URL, path: URL, head: String, branch: String?, isMain: Bool, isLocked: Bool,
        isPrunable: Bool, status: WorktreeStatus, operationInProgress: Bool, evidence: MergeEvidence,
        verdict: Verdict, agentHint: String?
    ) {
        self.repoRoot = repoRoot
        self.path = path
        self.head = head
        self.branch = branch
        self.isMain = isMain
        self.isLocked = isLocked
        self.isPrunable = isPrunable
        self.status = status
        self.operationInProgress = operationInProgress
        self.evidence = evidence
        self.verdict = verdict
        self.agentHint = agentHint
    }
}

public struct RepoSnapshot: Sendable, Equatable {
    public let repo: Repo
    public let branches: [BranchEntry]
    public let worktrees: [WorktreeEntry]
    /// False when no provider was configured or the provider failed (gh missing, not signed in, ...).
    public let prDetectionAvailable: Bool
    public let scannedAt: Date

    public init(
        repo: Repo, branches: [BranchEntry], worktrees: [WorktreeEntry],
        prDetectionAvailable: Bool, scannedAt: Date
    ) {
        self.repo = repo
        self.branches = branches
        self.worktrees = worktrees
        self.prDetectionAvailable = prDetectionAvailable
        self.scannedAt = scannedAt
    }
}

public enum AgentHint {
    /// Heuristic label for worktrees created by AI coding agents. Informational only.
    public static func detect(path: String, branch: String?) -> String? {
        let pathMarkers: [(String, String)] = [
            ("/.claude/worktrees/", "Claude Code"),
            ("/.cursor/worktrees/", "Cursor"),
            ("/.codex/worktrees/", "Codex"),
        ]
        for (marker, label) in pathMarkers where path.contains(marker) { return label }
        guard let branch else { return nil }
        let branchMarkers: [(String, String)] = [
            ("claude/", "Claude Code"),
            ("worktree-", "Claude Code"),
            ("cursor/", "Cursor"),
            ("codex/", "Codex"),
        ]
        for (prefix, label) in branchMarkers where branch.hasPrefix(prefix) { return label }
        return nil
    }
}
