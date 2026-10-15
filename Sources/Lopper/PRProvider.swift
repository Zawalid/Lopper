import Foundation

public struct MergedPR: Sendable, Equatable {
    public let number: Int
    public let headBranch: String
    public let headSHA: String
    /// The branch the PR was merged into. Evidence only counts when this is the repo's default branch.
    public let baseBranch: String

    public init(number: Int, headBranch: String, headSHA: String, baseBranch: String) {
        self.number = number
        self.headBranch = headBranch
        self.headSHA = headSHA
        self.baseBranch = baseBranch
    }
}

/// Source of merged pull requests for a repository. One call per repo; the result is matched locally.
public protocol PRProvider: Sendable {
    func mergedPullRequests(in repoRoot: URL) async throws -> [MergedPR]
}
