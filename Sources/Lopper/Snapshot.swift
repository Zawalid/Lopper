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
}

public struct RepoSnapshot: Sendable, Equatable {
    public let repo: Repo
    public let branches: [BranchEntry]
    public let worktrees: [WorktreeEntry]
    /// False when no provider was configured or the provider failed (gh missing, not signed in, ...).
    public let prDetectionAvailable: Bool
    public let scannedAt: Date
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
