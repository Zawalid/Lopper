import Foundation

/// Why a worktree was not removed, in terms a person can act on. Classified from the words the engine already
/// reports, so the same sentence works for git's own refusal and for Lopper's last-moment checks.
public enum RemovalRefusal: Sendable, Equatable {
    /// Modified, staged or untracked files that exist only in the folder.
    case hasChanges
    case locked
    case submodules
    /// Someone changed the item between the review and the removal.
    case changedSinceReview
    case other

    public static func classify(_ message: String) -> RemovalRefusal {
        let text = message.lowercased()
        if text.contains("modified or untracked files") || text.contains("exists only in this folder") { return .hasChanges }
        if text.contains("locked") { return .locked }
        if text.contains("submodules") { return .submodules }
        if text.contains("changed after you reviewed") || text.contains("moved after") { return .changedSinceReview }
        return .other
    }

    /// The one sentence shown under the item's name.
    public var sentence: String {
        switch self {
        case .hasChanges: "This folder has changes that exist only here, and git won't remove it until they are saved or moved."
        case .locked: "This worktree is locked, usually on purpose, so it was left alone."
        case .submodules: "This worktree contains submodules, which git won't remove on its own."
        case .changedSinceReview: "This changed after you reviewed it, so it was left alone."
        case .other: "Lopper couldn't remove this."
        }
    }

    /// Only a folder whose files are the problem can be moved to the Trash instead: the other reasons are not
    /// about files, so moving the folder would not be what the person is being protected from.
    public var allowsKeepingACopy: Bool { self == .hasChanges }
}

/// One file that stands in the way of removing a worktree.
public struct WorktreeChange: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        case modified, added, deleted, renamed, untracked, conflicted

        public var label: String {
            switch self {
            case .modified: "Changed"
            case .added: "New, staged"
            case .deleted: "Deleted"
            case .renamed: "Renamed"
            case .untracked: "Not tracked"
            case .conflicted: "Conflict"
            }
        }
    }

    public let path: String
    public let kind: Kind

    public var id: String { path }

    public init(path: String, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

/// The files that make git refuse to remove a worktree: what is modified, staged, or not tracked. Ignored files
/// are left out because git does not count them either. Read only.
public struct WorktreeChanges: Sendable, Equatable {
    public let files: [WorktreeChange]
    /// Every file there is, including the ones past the cap.
    public let total: Int

    public var hiddenCount: Int { max(0, total - files.count) }

    public static let defaultLimit = 200

    public init(files: [WorktreeChange], total: Int) {
        self.files = files
        self.total = total
    }

    public static let none = WorktreeChanges(files: [], total: 0)

    public static func read(at folder: URL, git: GitRunner = GitRunner(), limit: Int = defaultLimit) async -> WorktreeChanges {
        guard FileManager.default.fileExists(atPath: folder.path),
            let output = try? await git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: folder),
            output.succeeded
        else { return .none }
        let all = parse(output.stdout)
        return WorktreeChanges(files: Array(all.prefix(max(limit, 0))), total: all.count)
    }

    /// `git status --porcelain=v1 -z`: `XY path`, with a rename followed by an extra "from" field.
    static func parse(_ text: String) -> [WorktreeChange] {
        var changes: [WorktreeChange] = []
        var fields = text.split(separator: "\u{0}", omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            guard field.count > 3 else { continue }
            let code = String(field.prefix(2))
            let path = String(field.dropFirst(3))
            if code.contains("R") || code.contains("C") { _ = fields.next() }
            if code == "!!" { continue }
            changes.append(WorktreeChange(path: path, kind: kind(of: code)))
        }
        return changes
    }

    private static func kind(of code: String) -> WorktreeChange.Kind {
        if code == "??" { return .untracked }
        if code.contains("U") || code == "AA" || code == "DD" { return .conflicted }
        if code.contains("R") || code.contains("C") { return .renamed }
        if code.contains("D") { return .deleted }
        if code.contains("A") { return .added }
        return .modified
    }
}
