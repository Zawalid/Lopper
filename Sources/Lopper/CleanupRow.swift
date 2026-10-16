import Foundation

/// What the engine knows about a row beyond its verdict, kept for the details panel.
public struct RowFacts: Equatable, Sendable {
    public var evidence: MergeEvidence
    public var tip: String?
    public var upstream: String?
    public var ahead: Int?
    public var behind: Int?
    public var isDirty: Bool
    public var defaultBranch: String?
    public var prDetectionAvailable: Bool

    public init(
        evidence: MergeEvidence = .none, tip: String? = nil, upstream: String? = nil, ahead: Int? = nil,
        behind: Int? = nil, isDirty: Bool = false, defaultBranch: String? = nil, prDetectionAvailable: Bool = true
    ) {
        self.evidence = evidence
        self.tip = tip
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.isDirty = isDirty
        self.defaultBranch = defaultBranch
        self.prDetectionAvailable = prDetectionAvailable
    }
}

/// One line in the workbench or the CLI list: a branch, or a worktree (which carries its branch with it).
public struct CleanupRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case branch, worktree }

    public let id: String
    public let kind: Kind
    public let repoRoot: URL
    public let repoName: String
    public let title: String
    /// Folder for worktrees, "Local branch" for branches.
    public let location: String
    public let path: URL?
    public let verdict: VerdictKind
    public let reasons: [String]
    public let evidence: String
    public let prNumber: Int?
    public let prURL: URL?
    public let lastCommit: Date?
    public let size: Int64?
    public let agentHint: String?
    public let extraFiles: [String]
    /// The branch removed together with a Safe worktree.
    public let bundledBranch: String?
    public var facts: RowFacts
    /// The Agents page's reading of this worktree; nil unless a known tool made it.
    public var agent: AgentAssessment?

    public init(
        id: String, kind: Kind, repoRoot: URL, repoName: String, title: String, location: String, path: URL?,
        verdict: VerdictKind, reasons: [String], evidence: String, prNumber: Int?, prURL: URL?, lastCommit: Date?,
        size: Int64?, agentHint: String?, extraFiles: [String], bundledBranch: String?,
        facts: RowFacts = RowFacts(), agent: AgentAssessment? = nil
    ) {
        self.id = id
        self.kind = kind
        self.repoRoot = repoRoot
        self.repoName = repoName
        self.title = title
        self.location = location
        self.path = path
        self.verdict = verdict
        self.reasons = reasons
        self.evidence = evidence
        self.prNumber = prNumber
        self.prURL = prURL
        self.lastCommit = lastCommit
        self.size = size
        self.agentHint = agentHint
        self.extraFiles = extraFiles
        self.bundledBranch = bundledBranch
        self.facts = facts
        self.agent = agent
    }

    public var isSelectable: Bool { verdict != .protected }

    /// Safe, and for an agent worktree also finished, merged, clean, idle and measured. Every "clean all safe"
    /// shortcut and the safe counts use this, so a worktree an agent may still be using is never swept up.
    public var isBulkEligible: Bool { verdict == .safe && (agent?.isReclaimable ?? true) }

    /// Why an agent worktree cannot go to the review sheet from the inspector (still in use, or work that
    /// exists only in its folder), so no button opens a sheet the Agents page would not offer. Nil for rows
    /// no agent made and for rows that can be reviewed.
    public var agentHeldBackReason: String? {
        guard let agent, !(agent.isReclaimable || agent.canReview) else { return nil }
        if agent.state == .active { return "Still in use, or measuring. Lopper leaves it alone for now." }
        return agent.sheetNote.isEmpty ? "Lopper will not remove this from here." : agent.sheetNote
    }

    public var lastCommitSort: Date { lastCommit ?? .distantPast }
    public var sizeSort: Int64 { size ?? -1 }

    /// What the engine should do for this row, or nil for Protected rows.
    public var cleanupItem: CleanupItem? {
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

public enum RowMapper {
    /// Branches checked out in a linked worktree are represented by that worktree's row; the main
    /// working directory is the repository itself and gets no row.
    public static func rows(
        for snapshot: RepoSnapshot, sizes: [String: DiskUsage],
        policy: AgentPolicy = AgentPolicy(), now: Date = Date(), measuredPaths: Set<String>? = nil
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
                facts: RowFacts(
                    evidence: worktree.evidence,
                    tip: snapshot.branches.first { $0.name == worktree.branch }?.tip ?? worktree.head,
                    upstream: snapshot.branches.first { $0.name == worktree.branch }?.upstream,
                    ahead: snapshot.branches.first { $0.name == worktree.branch }?.ahead,
                    behind: snapshot.branches.first { $0.name == worktree.branch }?.behind,
                    isDirty: worktree.status.isDirty,
                    defaultBranch: repo.defaultBranch,
                    prDetectionAvailable: snapshot.prDetectionAvailable),
                // A size measured before the latest scan still fills the Size column, but its activity time is
                // stale: the folder may have been recreated or switched to other work since.
                agent: AgentAssessor.assess(
                    worktree: worktree,
                    usage: measuredPaths.map { $0.contains(worktree.path.path) } ?? true
                        ? sizes[worktree.path.path] : nil,
                    policy: policy, now: now)))
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
                bundledBranch: nil,
                facts: RowFacts(
                    evidence: branch.evidence, tip: branch.tip, upstream: branch.upstream,
                    ahead: branch.ahead, behind: branch.behind, isDirty: false,
                    defaultBranch: repo.defaultBranch, prDetectionAvailable: snapshot.prDetectionAvailable)))
        }

        return rows.sorted(by: defaultOrder)
    }

    /// Safe first, then Review, then Protected; oldest work first inside each group.
    public static func defaultOrder(_ lhs: CleanupRow, _ rhs: CleanupRow) -> Bool {
        if lhs.verdict != rhs.verdict { return lhs.verdict < rhs.verdict }
        if lhs.lastCommitSort != rhs.lastCommitSort { return lhs.lastCommitSort < rhs.lastCommitSort }
        return lhs.title < rhs.title
    }

    public static func prNumber(_ evidence: MergeEvidence) -> Int? {
        switch evidence {
        case .prMerged(let number), .prMergedWithNewerCommits(let number): number
        default: nil
        }
    }

    public static func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
