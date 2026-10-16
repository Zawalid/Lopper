import Foundation

/// Work that exists only on this Mac: losing the folder, or the Mac, would lose it for good.
/// This is the opposite of a cleanup list, so nothing here is ever offered for removal.
public struct LocalOnlyItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// Commits on a local branch that no remote branch has.
        case unpushedCommits
        /// A linked worktree with uncommitted changes or untracked files.
        case uncommittedChanges
        /// A stash entry. Stashes are never pushed.
        case stash
        /// Commits reachable from a detached worktree head only, so no branch, tag or remote has them.
        case detachedCommits
        /// A rebase, merge or similar operation left half done.
        case operationInProgress
    }

    public let id: String
    public let kind: Kind
    public let repoRoot: URL
    public let repoName: String
    /// The branch, the worktree folder name, or the stash message.
    public let title: String
    /// One line saying what exists only here.
    public let detail: String
    /// Commits, files or stash entries the detail talks about; 0 when no number applies.
    public let count: Int
    public let lastTouched: Date?
    /// The worktree folder, when the item lives in one.
    public let path: URL?
    public let branch: String?
    /// A command that would back it up. Lopper only offers it for copying and never runs it.
    public let pushCommand: String?

    public init(
        id: String, kind: Kind, repoRoot: URL, repoName: String, title: String, detail: String, count: Int = 0,
        lastTouched: Date? = nil, path: URL? = nil, branch: String? = nil, pushCommand: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.repoRoot = repoRoot
        self.repoName = repoName
        self.title = title
        self.detail = detail
        self.count = count
        self.lastTouched = lastTouched
        self.path = path
        self.branch = branch
        self.pushCommand = pushCommand
    }
}

/// Finds what exists only on this Mac in repositories that were already scanned.
/// It adds a few cheap git calls: one count per branch that has commits of its own, and one stash list per repository.
public struct LocalWorkScanner: Sendable {
    private let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    public func scan(_ snapshots: [RepoSnapshot]) async -> [LocalOnlyItem] {
        var items: [LocalOnlyItem] = []
        // Four repositories at a time keeps a large scan from starting hundreds of git processes at once.
        var index = 0
        while index < snapshots.count {
            let batch = snapshots[index..<min(index + 4, snapshots.count)]
            let found = await withTaskGroup(of: [LocalOnlyItem].self) { group in
                for snapshot in batch { group.addTask { await scan(snapshot) } }
                var all: [LocalOnlyItem] = []
                for await part in group { all += part }
                return all
            }
            items += found
            index += 4
        }
        return items.sorted(by: Self.order)
    }

    /// Unpushed work first, then the rest; newest first inside each group, so the most recent work leads.
    public static func order(_ lhs: LocalOnlyItem, _ rhs: LocalOnlyItem) -> Bool {
        if lhs.repoRoot != rhs.repoRoot { return lhs.repoName.localizedStandardCompare(rhs.repoName) == .orderedAscending }
        if lhs.kind != rhs.kind { return rank(lhs.kind) < rank(rhs.kind) }
        return (lhs.lastTouched ?? .distantPast) > (rhs.lastTouched ?? .distantPast)
    }

    private static func rank(_ kind: LocalOnlyItem.Kind) -> Int {
        switch kind {
        case .unpushedCommits: 0
        case .detachedCommits: 1
        case .uncommittedChanges: 2
        case .stash: 3
        case .operationInProgress: 4
        }
    }

    public func scan(_ snapshot: RepoSnapshot) async -> [LocalOnlyItem] {
        let repo = snapshot.repo
        let hasRemoteRefs = await hasRemoteRefs(repo.root)
        var items: [LocalOnlyItem] = []

        for branch in snapshot.branches {
            let isDefault = branch.name == repo.defaultBranch
            // Nothing beyond the default branch (it carries those commits), or the content is already merged.
            if !isDefault && (branch.ahead == 0 || branch.evidence.isStrong) { continue }
            let count: Int
            if hasRemoteRefs {
                count = await unpushedCount(of: branch.tip, excluding: isDefault ? nil : repo.defaultBranch, in: repo.root)
            } else if isDefault {
                // A repository with no remote at all is local as a whole; flagging its main branch says nothing new.
                continue
            } else {
                count = branch.ahead
            }
            guard count > 0 else { continue }
            let detail = hasRemoteRefs
                ? "\(Self.commits(count)) not on any remote"
                : "\(Self.commits(count)); this repository has no remote"
            items.append(LocalOnlyItem(
                id: "unpushed:\(repo.root.path)#\(branch.name)", kind: .unpushedCommits, repoRoot: repo.root,
                repoName: repo.name, title: branch.name, detail: detail, count: count, lastTouched: branch.lastCommit,
                path: branch.checkedOutAt, branch: branch.name,
                pushCommand: repo.remoteURL == nil ? nil : "git -C \(Self.quoted(repo.root.path)) push -u origin \(Self.quoted(branch.name))"))
        }

        for worktree in snapshot.worktrees {
            if worktree.operationInProgress {
                items.append(LocalOnlyItem(
                    id: "operation:\(worktree.path.path)", kind: .operationInProgress, repoRoot: repo.root,
                    repoName: repo.name, title: worktree.branch ?? worktree.path.lastPathComponent,
                    detail: "A rebase, merge or similar operation is half done here", lastTouched: worktree.lastCommit,
                    path: worktree.path, branch: worktree.branch))
            }
            if worktree.isMain { continue }
            if worktree.status.isDirty || !worktree.status.extraFiles.isEmpty {
                let extra = worktree.status.extraFiles.count
                var parts: [String] = []
                if worktree.status.isDirty { parts.append("uncommitted changes") }
                if extra > 0 { parts.append("\(extra) untracked \(extra == 1 ? "file" : "files")") }
                items.append(LocalOnlyItem(
                    id: "uncommitted:\(worktree.path.path)", kind: .uncommittedChanges, repoRoot: repo.root,
                    repoName: repo.name, title: worktree.branch ?? worktree.path.lastPathComponent,
                    detail: sentence(parts.joined(separator: " and ")),
                    count: extra, lastTouched: worktree.lastCommit, path: worktree.path, branch: worktree.branch))
            }
            if worktree.branch == nil, !worktree.isPrunable {
                let count = await detachedCount(of: worktree.head, in: repo.root)
                if count > 0 {
                    items.append(LocalOnlyItem(
                        id: "detached:\(worktree.path.path)", kind: .detachedCommits, repoRoot: repo.root,
                        repoName: repo.name, title: worktree.path.lastPathComponent,
                        detail: "\(Self.commits(count)) that no branch, tag or remote has",
                        count: count, lastTouched: worktree.lastCommit, path: worktree.path))
                }
            }
        }

        items += await stashes(of: snapshot)
        return items
    }

    private func hasRemoteRefs(_ root: URL) async -> Bool {
        guard let output = try? await git.run(["for-each-ref", "refs/remotes", "--count=1", "--format=%(refname)"], in: root),
            output.succeeded else { return false }
        return !output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Commits reachable from `tip` that no remote branch has, leaving out what the default branch already carries
    /// (the default branch is reported on its own).
    private func unpushedCount(of tip: String, excluding defaultBranch: String?, in root: URL) async -> Int {
        var arguments = ["rev-list", "--count", tip, "--not", "--remotes"]
        if let defaultBranch { arguments.append(defaultBranch) }
        return await count(arguments, in: root)
    }

    private func detachedCount(of head: String, in root: URL) async -> Int {
        await count(["rev-list", "--count", head, "--not", "--branches", "--remotes", "--tags"], in: root)
    }

    private func count(_ arguments: [String], in root: URL) async -> Int {
        guard let output = try? await git.run(arguments, in: root), output.succeeded else { return 0 }
        return Int(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private func stashes(of snapshot: RepoSnapshot) async -> [LocalOnlyItem] {
        let repo = snapshot.repo
        guard let output = try? await git.run(["stash", "list", "--format=%gd%x00%gs%x00%ct"], in: repo.root),
            output.succeeded else { return [] }
        return output.stdout.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else { return nil }
            let seconds = TimeInterval(fields[2]) ?? 0
            let branches = GitParsers.parseStashBranches(fields[1])
            return LocalOnlyItem(
                id: "stash:\(repo.root.path)#\(fields[0])", kind: .stash, repoRoot: repo.root, repoName: repo.name,
                title: fields[0], detail: Self.stashDetail(message: fields[1], branches: branches),
                lastTouched: Date(timeIntervalSince1970: seconds), branch: branches.first)
        }
    }

    private static func stashDetail(message: String, branches: Set<String>) -> String {
        // "WIP on feature/x: abc123 message" reads better as "On feature/x: message".
        if let colon = message.firstIndex(of: ":") {
            let rest = message[message.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let words = rest.split(separator: " ", maxSplits: 1)
            let text = words.count == 2 && words[0].count >= 7 && words[0].allSatisfy(\.isHexDigit) ? String(words[1]) : rest
            if let branch = branches.first { return text.isEmpty ? "Stashed on \(branch)" : "Stashed on \(branch): \(text)" }
        }
        return message
    }

    private func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func commits(_ count: Int) -> String { "\(count) \(count == 1 ? "commit" : "commits")" }

    private static func quoted(_ text: String) -> String {
        text.range(of: "^[A-Za-z0-9_./@:+-]+$", options: .regularExpression) != nil
            ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
