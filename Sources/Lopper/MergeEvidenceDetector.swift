import Foundation

/// Decides how strongly a commit's content is already contained in the default branch.
public struct MergeEvidenceDetector: Sendable {
    private let git: GitRunner
    private let repoRoot: URL
    /// Existing full ref names of the default branch (local and remote-tracking).
    public let defaultRefs: [String]

    public init(git: GitRunner, repoRoot: URL, defaultRefs: [String]) {
        self.git = git
        self.repoRoot = repoRoot
        self.defaultRefs = defaultRefs
    }

    /// Strongest first: PR match, ancestry, content equality, then the weaker signals.
    public func evidence(
        tip: String,
        branchName: String?,
        upstreamGone: Bool,
        mergedPRs: [MergedPR]
    ) async -> MergeEvidence {
        let candidates = branchName.map { name in mergedPRs.filter { $0.headBranch == name } } ?? []
        for pr in candidates {
            if pr.headSHA == tip { return .prMerged(number: pr.number) }
            if await isAncestor(tip, of: pr.headSHA) { return .prMerged(number: pr.number) }
        }
        for ref in defaultRefs where await isAncestor(tip, of: ref) {
            return .ancestorOfDefault
        }
        for ref in defaultRefs where await contentIncluded(tip: tip, in: ref) {
            return .contentIncluded
        }
        if let newest = candidates.map(\.number).max() {
            return .prMergedWithNewerCommits(number: newest)
        }
        return upstreamGone ? .upstreamGone : .none
    }

    func isAncestor(_ commit: String, of ref: String) async -> Bool {
        guard let output = try? await git.run(["merge-base", "--is-ancestor", commit, ref], in: repoRoot) else {
            return false
        }
        return output.exitCode == 0
    }

    /// True when merging `tip` into `ref` would change nothing (squash and rebase merges), or when
    /// every commit of `tip` has a patch-equivalent commit in `ref`.
    func contentIncluded(tip: String, in ref: String) async -> Bool {
        if let merge = try? await git.run(
            ["merge-tree", "--write-tree", "--no-messages", ref, tip], in: repoRoot),
            merge.exitCode == 0,
            let mergedTree = merge.stdout.split(separator: "\n").first.map(String.init),
            let refTree = try? await git.runChecked(["rev-parse", "\(ref)^{tree}"], in: repoRoot),
            mergedTree == refTree
        {
            return true
        }
        if let cherry = try? await git.run(["cherry", ref, tip], in: repoRoot), cherry.succeeded {
            let lines = cherry.stdout.split(separator: "\n")
            return !lines.isEmpty && lines.allSatisfy { $0.hasPrefix("-") }
        }
        return false
    }
}
