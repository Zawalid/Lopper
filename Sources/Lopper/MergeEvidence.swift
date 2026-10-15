import Foundation

/// The strongest proof that a branch's content already lives in the default branch.
public enum MergeEvidence: Sendable, Equatable {
    case prMerged(number: Int)
    case ancestorOfDefault
    case contentIncluded
    /// A merged PR exists for this branch name, but the local tip has commits the PR did not contain.
    case prMergedWithNewerCommits(number: Int)
    case upstreamGone
    case none

    /// Strong evidence means the content of the branch tip is already in the default branch.
    public var isStrong: Bool {
        switch self {
        case .prMerged, .ancestorOfDefault, .contentIncluded: true
        case .prMergedWithNewerCommits, .upstreamGone, .none: false
        }
    }

    public var summary: String {
        switch self {
        case .prMerged(let number): "Merged via PR #\(number)"
        case .ancestorOfDefault: "Already part of the default branch"
        case .contentIncluded: "Content already in the default branch (squash or rebase merge)"
        case .prMergedWithNewerCommits(let number): "PR #\(number) was merged, but this branch has newer commits"
        case .upstreamGone: "Remote branch was deleted"
        case .none: "No merge evidence"
        }
    }
}
