import Foundation

/// Decides how strongly a commit's content is already contained in the default branch.
public struct MergeEvidenceDetector: Sendable {
    private let git: GitRunner
    private let repoRoot: URL
    /// Existing full ref names of the default branch (local and remote-tracking).
    public let defaultRefs: [String]
    /// Tips already known (from one `git for-each-ref --merged` call) to be part of a default ref. For a tip listed in
    /// `coveredTips` the answer is a lookup instead of a git process; a tip that is not covered is asked about directly.
    private let ancestorTips: Set<String>
    private let coveredTips: Set<String>
    private let trees = TreeCache()

    public init(
        git: GitRunner, repoRoot: URL, defaultRefs: [String],
        ancestorTips: Set<String> = [], coveredTips: Set<String> = []
    ) {
        self.git = git
        self.repoRoot = repoRoot
        self.defaultRefs = defaultRefs
        self.ancestorTips = ancestorTips
        self.coveredTips = coveredTips
    }

    /// The tree of a ref, asked once per detector: every unmerged branch compares against the same one.
    private final class TreeCache: @unchecked Sendable {
        private let lock = NSLock()
        private var trees: [String: String] = [:]

        func tree(of ref: String, load: () async -> String?) async -> String? {
            if let known = lookup(ref) { return known }
            guard let loaded = await load() else { return nil }
            store(loaded, for: ref)
            return loaded
        }

        private func lookup(_ ref: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return trees[ref]
        }

        private func store(_ tree: String, for ref: String) {
            lock.lock()
            defer { lock.unlock() }
            trees[ref] = tree
        }
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
        if coveredTips.contains(tip) {
            if ancestorTips.contains(tip) { return .ancestorOfDefault }
        } else {
            for ref in defaultRefs where await isAncestor(tip, of: ref) {
                return .ancestorOfDefault
            }
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
            let refTree = await trees.tree(of: ref, load: {
                try? await git.runChecked(["rev-parse", "\(ref)^{tree}"], in: repoRoot)
            }),
            mergedTree == refTree
        {
            return true
        }
        if let cherry = try? await git.run(["cherry", ref, tip], in: repoRoot), cherry.succeeded {
            let lines = cherry.stdout.split(separator: "\n")
            guard !lines.isEmpty, lines.allSatisfy({ $0.hasPrefix("-") }) else { return false }
            // `git cherry` skips merge commits, so work that exists only in a merge commit (a conflict resolution, or an
            // "update branch" merge with real edits) would go unseen. With any merge on the branch, answer "not included".
            guard let merges = try? await git.run(["rev-list", "--merges", "--count", "\(ref)..\(tip)"], in: repoRoot),
                merges.succeeded,
                Int(merges.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) == 0
            else { return false }
            return true
        }
        return false
    }
}
