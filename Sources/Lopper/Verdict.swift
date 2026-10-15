import Foundation

public enum VerdictKind: String, Sendable, Codable, Equatable, Comparable {
    case safe
    case review
    case protected

    private var rank: Int {
        switch self {
        case .safe: 0
        case .review: 1
        case .protected: 2
        }
    }

    public static func < (lhs: VerdictKind, rhs: VerdictKind) -> Bool { lhs.rank < rhs.rank }
}

public enum VerdictReason: Sendable, Equatable {
    // Protected
    case isDefaultBranch
    case isMainWorktreeHead
    case checkedOut(inWorktree: String)
    case matchesProtectedPattern(String)
    // Review
    case noMergeEvidence
    case upstreamGoneOnly
    case commitsAfterMergedPR(number: Int)
    case worktreeDirty
    case worktreeLocked
    case worktreeUnreadable
    case worktreeHasExtraFiles([String])
    case operationInProgress
    case hasStash
    // Safe
    case mergedVia(MergeEvidence)
    case noOwnCommits

    public var text: String {
        switch self {
        case .isDefaultBranch: "This is the default branch"
        case .isMainWorktreeHead: "Checked out in the main working directory"
        case .checkedOut(let path): "Checked out in worktree \(path)"
        case .matchesProtectedPattern(let pattern): "Matches protected pattern \(pattern)"
        case .noMergeEvidence: "No evidence this work was merged"
        case .upstreamGoneOnly: "The remote branch is gone, but nothing proves it was merged"
        case .commitsAfterMergedPR(let number): "Has commits added after PR #\(number) was merged"
        case .worktreeDirty: "The worktree has uncommitted changes"
        case .worktreeLocked: "The worktree is locked"
        case .worktreeUnreadable: "The worktree could not be inspected, so it is not known to be clean"
        case .worktreeHasExtraFiles(let files):
            "Contains files git does not track: \(files.prefix(3).joined(separator: ", "))"
        case .operationInProgress: "A rebase, merge or similar operation is in progress"
        case .hasStash: "A stash entry belongs to this branch"
        case .mergedVia(let evidence): evidence.summary
        case .noOwnCommits: "Has no commits of its own"
        }
    }
}

public struct Verdict: Sendable, Equatable {
    public let kind: VerdictKind
    public let reasons: [VerdictReason]
    public let evidence: MergeEvidence

    public init(kind: VerdictKind, reasons: [VerdictReason], evidence: MergeEvidence) {
        self.kind = kind
        self.reasons = reasons
        self.evidence = evidence
    }
}
