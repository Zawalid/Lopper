import Foundation

public enum AgentState: String, Sendable, Equatable, Codable, CaseIterable {
    /// Merged, clean and idle: everything in it is already in the default branch.
    case finished
    /// Touched recently (or activity unknown): possibly still in use.
    case active
    /// Holds work that is not in the default branch, or that exists only in the folder.
    case unmerged
    /// Idle for a long time and everything not merged is committed, so removing the folder loses nothing.
    case abandoned
    case protected
}

public struct AgentPolicy: Sendable, Equatable {
    /// A worktree touched more recently than this is Active.
    public var finishedGrace: TimeInterval
    /// Unmerged but fully committed work idle for this long is Abandoned.
    public var abandonedAfter: TimeInterval

    public init(finishedGrace: TimeInterval = 7_200, abandonedAfter: TimeInterval = 30 * 86_400) {
        self.finishedGrace = finishedGrace
        self.abandonedAfter = abandonedAfter
    }

    public init(settings: Settings) {
        self.init(
            finishedGrace: TimeInterval(settings.agentFinishedGraceMinutes) * 60,
            abandonedAfter: TimeInterval(settings.staleDays) * 86_400)
    }
}

/// What a worktree holds that the default branch does not.
public struct UniqueWork: Sendable, Equatable {
    /// Commits the default branch does not have (0 when merge evidence is strong).
    public var commits: Int
    /// There is no strong evidence and the commit count is 0: the default branch is probably unknown, so
    /// the comparison proves nothing. Treated as unique work.
    public var isComparisonUnknown: Bool
    public var hasUncommittedChanges: Bool
    public var untrackedFiles: [String]
    public var hasStash: Bool
    public var operationInProgress: Bool
    public var isUnreadable: Bool
    public var isDetached: Bool

    /// Work that lives only in the worktree folder and would be lost by removing it.
    public var existsOnlyInFolder: Bool {
        hasUncommittedChanges || !untrackedFiles.isEmpty || operationInProgress || isUnreadable
    }

    public var isEmpty: Bool {
        commits == 0 && !isComparisonUnknown && !existsOnlyInFolder && !hasStash
    }

    /// One short phrase for a table cell: "3 commits, 2 untracked files", or "None".
    public var summary: String {
        var parts: [String] = []
        if commits > 0 { parts.append(commits == 1 ? "1 commit" : "\(commits) commits") }
        if isComparisonUnknown { parts.append("commits not compared") }
        if hasUncommittedChanges { parts.append("uncommitted changes") }
        if !untrackedFiles.isEmpty {
            parts.append(untrackedFiles.count == 1 ? "1 untracked file" : "\(untrackedFiles.count) untracked files")
        }
        if hasStash { parts.append("a stash entry") }
        if operationInProgress { parts.append("an operation in progress") }
        if isUnreadable { parts.append("folder not readable") }
        return parts.isEmpty ? "None" : parts.joined(separator: ", ")
    }
}

public enum AgentRemoval: Sendable, Equatable {
    /// No removal is offered (active, protected).
    case notOffered
    /// Merged and clean: remove the folder and its branch.
    case reclaim
    /// Remove the folder only; the named branch keeps the commits.
    case keepBranch(String)
    /// Detached HEAD: the commits are saved under this new branch, then the folder is removed.
    case saveAsBranch(String)
    /// Lopper will not remove this; the text says why and what to do.
    case blocked(String)

    public var keepsWorkOnABranch: Bool {
        switch self {
        case .keepBranch, .saveAsBranch: true
        case .notOffered, .reclaim, .blocked: false
        }
    }
}

public struct AgentAssessment: Sendable, Equatable {
    public let detection: AgentDetection
    public let state: AgentState
    public let uniqueWork: UniqueWork
    public let lastActivity: Date?
    public let createdAt: Date?
    /// False while the folder has not been walked yet. Nothing is bulk-eligible until it is measured.
    public let isActivityMeasured: Bool
    public let removal: AgentRemoval

    /// Part of "Reclaim finished".
    public var isReclaimable: Bool {
        state == .finished && isActivityMeasured && removal == .reclaim
    }

    /// Part of "Reclaim abandoned, keep branches" (always goes through the Review step).
    public var isReviewReclaimable: Bool {
        state == .abandoned && isActivityMeasured && removal.keepsWorkOnABranch
    }

    /// A single row can be sent to the Review step.
    public var canReview: Bool {
        isActivityMeasured && removal.keepsWorkOnABranch && (state == .unmerged || state == .abandoned)
    }

    /// One sentence for the Review sheet and the inspector that says what removal does and keeps.
    public var sheetNote: String {
        switch removal {
        case .reclaim:
            return "Already merged. Nothing is lost."
        case .keepBranch(let branch):
            let commits = uniqueWork.commits
            let kept = commits > 0 ? "keeps \(commits == 1 ? "1 commit" : "\(commits) commits")" : "is kept"
            return "The folder is removed. Branch \(branch) \(kept)."
        case .saveAsBranch(let name):
            return "No branch holds this work. It is saved as \(name) first, then the folder is removed."
        case .blocked(let reason):
            return reason
        case .notOffered:
            return ""
        }
    }
}

public enum AgentAssessor {
    /// Nil for the main working directory and for worktrees no known tool made.
    public static func assess(
        worktree: WorktreeEntry, usage: DiskUsage?, policy: AgentPolicy, now: Date
    ) -> AgentAssessment? {
        guard !worktree.isMain, let detection = worktree.agent else { return nil }

        let reasons = worktree.verdict.reasons
        let strong = worktree.evidence.isStrong
        let work = UniqueWork(
            commits: strong ? 0 : worktree.ahead,
            isComparisonUnknown: !strong && worktree.ahead == 0,
            hasUncommittedChanges: worktree.status.isDirty,
            untrackedFiles: worktree.status.extraFiles,
            hasStash: reasons.contains(.hasStash),
            operationInProgress: worktree.operationInProgress,
            isUnreadable: reasons.contains(.worktreeUnreadable),
            isDetached: worktree.branch == nil)

        let activity = [worktree.lastCommit, usage?.newestModification].compactMap { $0 }.max()
        let idle = activity.map { now.timeIntervalSince($0) }
        let measured = usage != nil || worktree.isPrunable

        let state: AgentState
        if worktree.verdict.kind == .protected {
            state = .protected
        } else if let idle, idle >= policy.finishedGrace {
            if work.existsOnlyInFolder || work.isComparisonUnknown {
                state = .unmerged
            } else if work.commits > 0 || work.hasStash {
                state = idle >= policy.abandonedAfter ? .abandoned : .unmerged
            } else {
                state = .finished
            }
        } else {
            state = .active
        }

        return AgentAssessment(
            detection: detection, state: state, uniqueWork: work, lastActivity: activity,
            createdAt: worktree.createdAt, isActivityMeasured: measured,
            removal: removal(for: state, worktree: worktree, work: work))
    }

    private static func removal(for state: AgentState, worktree: WorktreeEntry, work: UniqueWork) -> AgentRemoval {
        switch state {
        case .active, .protected:
            return .notOffered
        case .finished:
            if worktree.isLocked { return .blocked("The worktree is locked. Unlock it with git worktree unlock.") }
            return worktree.verdict.kind == .safe
                ? .reclaim : .blocked(worktree.verdict.reasons.first?.text ?? "Not safe to remove")
        case .unmerged, .abandoned:
            if work.existsOnlyInFolder {
                return .blocked("Changes exist only in this folder. Commit or move them first.")
            }
            if worktree.isLocked { return .blocked("The worktree is locked. Unlock it with git worktree unlock.") }
            if let branch = worktree.branch { return .keepBranch(branch) }
            return .saveAsBranch(Cleaner.savedBranchName(forWorktreeAt: worktree.path, head: worktree.head))
        }
    }
}
