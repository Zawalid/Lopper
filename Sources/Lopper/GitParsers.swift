import Foundation

public struct WorktreeListEntry: Sendable, Equatable {
    public let path: String
    public let head: String
    /// Short branch name, or nil when detached or bare.
    public let branch: String?
    public let isBare: Bool
    public let isLocked: Bool
    public let isPrunable: Bool

    public init(path: String, head: String, branch: String?, isBare: Bool, isLocked: Bool, isPrunable: Bool) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isBare = isBare
        self.isLocked = isLocked
        self.isPrunable = isPrunable
    }
}

public struct BranchRef: Sendable, Equatable {
    public let name: String
    public let tip: String
    public let upstream: String?
    public let upstreamGone: Bool
    public let lastCommit: Date
    /// True when this branch is checked out in the worktree the command ran in.
    public let isCurrent: Bool

    public init(name: String, tip: String, upstream: String?, upstreamGone: Bool, lastCommit: Date, isCurrent: Bool) {
        self.name = name
        self.tip = tip
        self.upstream = upstream
        self.upstreamGone = upstreamGone
        self.lastCommit = lastCommit
        self.isCurrent = isCurrent
    }
}

public struct WorktreeStatus: Sendable, Equatable {
    /// Tracked files were modified, staged, deleted or are in conflict.
    public var isDirty: Bool
    /// Untracked files and ignored files that are not on the disposable allowlist.
    public var extraFiles: [String]
    /// Ignored paths that match the disposable allowlist (node_modules, build output, ...).
    public var disposablePaths: [String]

    public init(isDirty: Bool = false, extraFiles: [String] = [], disposablePaths: [String] = []) {
        self.isDirty = isDirty
        self.extraFiles = extraFiles
        self.disposablePaths = disposablePaths
    }
}

public enum GitParsers {
    /// `git worktree list --porcelain -z`: NUL-terminated fields, an empty field ends each worktree block.
    /// The `-z` form is used so paths with spaces, accents or newlines are never quoted or split.
    public static func parseWorktreeList(_ text: String) -> [WorktreeListEntry] {
        var entries: [WorktreeListEntry] = []
        var fields: [Substring] = []

        func flush() {
            defer { fields.removeAll() }
            var path: String?
            var head = ""
            var branch: String?
            var isBare = false
            var isLocked = false
            var isPrunable = false
            for line in fields {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("HEAD ") {
                    head = String(line.dropFirst("HEAD ".count))
                } else if line.hasPrefix("branch ") {
                    let ref = String(line.dropFirst("branch ".count))
                    branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
                } else if line == "bare" {
                    isBare = true
                } else if line == "locked" || line.hasPrefix("locked ") {
                    isLocked = true
                } else if line == "prunable" || line.hasPrefix("prunable ") {
                    isPrunable = true
                }
            }
            if let path {
                entries.append(WorktreeListEntry(
                    path: path, head: head, branch: branch,
                    isBare: isBare, isLocked: isLocked, isPrunable: isPrunable))
            }
        }

        for field in text.split(separator: "\u{0}", omittingEmptySubsequences: false) {
            if field.isEmpty { flush() } else { fields.append(field) }
        }
        flush()
        return entries
    }

    /// Format string to pass to `git for-each-ref refs/heads --format=...`.
    public static let branchFormat =
        "%(refname:lstrip=2)%00%(objectname)%00%(upstream:short)%00%(upstream:track)%00%(committerdate:unix)%00%(HEAD)"

    /// Output of `git for-each-ref refs/heads --format=<branchFormat>`.
    public static func parseBranches(_ text: String) -> [BranchRef] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6 else { return nil }
            let seconds = TimeInterval(fields[4]) ?? 0
            return BranchRef(
                name: fields[0],
                tip: fields[1],
                upstream: fields[2].isEmpty ? nil : fields[2],
                upstreamGone: fields[3].contains("gone"),
                lastCommit: Date(timeIntervalSince1970: seconds),
                isCurrent: fields[5] == "*"
            )
        }
    }

    /// Branch names referenced by stash entries. Input is `git stash list --format=%gs`.
    public static func parseStashBranches(_ text: String) -> Set<String> {
        var names = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // "WIP on feature/x: abc123 message"  or  "On feature/x: message"
            let prefixes = ["WIP on ", "On "]
            for prefix in prefixes where line.hasPrefix(prefix) {
                let rest = line.dropFirst(prefix.count)
                if let colon = rest.firstIndex(of: ":") {
                    names.insert(String(rest[rest.startIndex..<colon]))
                }
                break
            }
        }
        return names
    }

    /// Output of `git status --porcelain=v1 -z --ignored --untracked-files=normal`.
    /// With `-z` paths are unquoted, and a rename or copy is followed by an extra "from" field.
    public static func parseStatus(_ text: String, disposable: Set<String>) -> WorktreeStatus {
        var status = WorktreeStatus()
        var fields = text.split(separator: "\u{0}", omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            guard field.count > 3 else { continue }
            let code = field.prefix(2)
            let path = String(field.dropFirst(3))
            if code.contains("R") || code.contains("C") {
                _ = fields.next()
            }
            switch code {
            case "!!", "??":
                // Ignored or merely untracked: either way it is disposable if it is a tool cache.
                if isDisposable(path, disposable: disposable) {
                    status.disposablePaths.append(path)
                } else {
                    status.extraFiles.append(path)
                }
            default:
                status.isDirty = true
            }
        }
        return status
    }

    /// True when any path component is on the allowlist. Entries containing `*` are glob patterns
    /// (for example `*.tsbuildinfo`); everything else is an exact name.
    public static func isDisposable(_ path: String, disposable: Set<String>) -> Bool {
        path.split(separator: "/").contains { matchesDisposable(String($0), disposable) }
    }

    public static func matchesDisposable(_ name: String, _ patterns: Set<String>) -> Bool {
        if patterns.contains(name) { return true }
        return patterns.contains { $0.contains("*") && GlobMatcher.matches(pattern: $0, name: name) }
    }
}
