import Foundation

public struct WorktreeConditions: Sendable, Equatable {
    public var isDirty: Bool
    public var isLocked: Bool
    public var extraFiles: [String]
    public var operationInProgress: Bool
    /// `git status` failed or timed out, so cleanliness is unknown. Unknown is never Safe.
    public var isUnreadable: Bool

    public init(
        isDirty: Bool = false, isLocked: Bool = false, extraFiles: [String] = [],
        operationInProgress: Bool = false, isUnreadable: Bool = false
    ) {
        self.isDirty = isDirty
        self.isLocked = isLocked
        self.extraFiles = extraFiles
        self.operationInProgress = operationInProgress
        self.isUnreadable = isUnreadable
    }
}

public struct ClassificationInput: Sendable, Equatable {
    public var branchName: String?
    public var evidence: MergeEvidence
    public var aheadOfDefault: Int
    public var isDefaultBranch: Bool
    /// The branch is checked out in the main working directory, or the item is the main worktree itself.
    public var isMainWorktreeHead: Bool
    /// Paths of other worktrees that have this branch checked out.
    public var checkedOutElsewhere: [String]
    public var protectedPatterns: [String]
    public var hasStash: Bool
    /// Present when the item being classified is a worktree rather than a bare branch.
    public var worktree: WorktreeConditions?

    public init(
        branchName: String?,
        evidence: MergeEvidence,
        aheadOfDefault: Int = 0,
        isDefaultBranch: Bool = false,
        isMainWorktreeHead: Bool = false,
        checkedOutElsewhere: [String] = [],
        protectedPatterns: [String] = [],
        hasStash: Bool = false,
        worktree: WorktreeConditions? = nil
    ) {
        self.branchName = branchName
        self.evidence = evidence
        self.aheadOfDefault = aheadOfDefault
        self.isDefaultBranch = isDefaultBranch
        self.isMainWorktreeHead = isMainWorktreeHead
        self.checkedOutElsewhere = checkedOutElsewhere
        self.protectedPatterns = protectedPatterns
        self.hasStash = hasStash
        self.worktree = worktree
    }
}

public enum Classifier {
    public static func classify(_ input: ClassificationInput) -> Verdict {
        var protectedReasons: [VerdictReason] = []
        if input.isDefaultBranch { protectedReasons.append(.isDefaultBranch) }
        if input.isMainWorktreeHead { protectedReasons.append(.isMainWorktreeHead) }
        for path in input.checkedOutElsewhere { protectedReasons.append(.checkedOut(inWorktree: path)) }
        if let name = input.branchName {
            for pattern in input.protectedPatterns where GlobMatcher.matches(pattern: pattern, name: name) {
                protectedReasons.append(.matchesProtectedPattern(pattern))
            }
        }
        if !protectedReasons.isEmpty {
            return Verdict(kind: .protected, reasons: protectedReasons, evidence: input.evidence)
        }

        var reviewReasons: [VerdictReason] = []
        switch input.evidence {
        case .prMerged, .ancestorOfDefault, .contentIncluded:
            break
        case .prMergedWithNewerCommits(let number):
            reviewReasons.append(.commitsAfterMergedPR(number: number))
        case .upstreamGone:
            reviewReasons.append(.upstreamGoneOnly)
        case .none:
            reviewReasons.append(.noMergeEvidence)
        }
        if let worktree = input.worktree {
            if worktree.isDirty { reviewReasons.append(.worktreeDirty) }
            if worktree.isLocked { reviewReasons.append(.worktreeLocked) }
            if worktree.isUnreadable { reviewReasons.append(.worktreeUnreadable) }
            if !worktree.extraFiles.isEmpty { reviewReasons.append(.worktreeHasExtraFiles(worktree.extraFiles)) }
            if worktree.operationInProgress { reviewReasons.append(.operationInProgress) }
        }
        if input.hasStash { reviewReasons.append(.hasStash) }
        if !reviewReasons.isEmpty {
            return Verdict(kind: .review, reasons: reviewReasons, evidence: input.evidence)
        }

        var safeReasons: [VerdictReason] = [.mergedVia(input.evidence)]
        if input.aheadOfDefault == 0 { safeReasons.append(.noOwnCommits) }
        return Verdict(kind: .safe, reasons: safeReasons, evidence: input.evidence)
    }
}
