import Foundation

/// When a branch was last switched to or from, which is a better sign of life than its last commit: someone
/// who checked a branch out yesterday has not abandoned it, whatever the commit dates say.
public enum BranchTouch {
    /// Read-only and tolerant: a missing reflog, an unknown branch or any git failure gives nil. Reflogs expire,
    /// so nil means "no recent record", not "never".
    public static func lastCheckedOut(branch: String, in directory: URL, git: GitRunner = GitRunner()) async -> Date? {
        guard !branch.isEmpty, !branch.hasPrefix("-") else { return nil }
        guard let log = try? await git.runChecked(
            ["reflog", "show", "HEAD", "--format=%cI%x1f%gs", "-n", "1000"], in: directory) else { return nil }
        return parse(reflog: log, branch: branch)
    }

    /// Lines of `ISO date, U+001F, subject`, newest first. A "checkout: moving from A to B" entry that names
    /// the branch on either side counts; the first match is the newest.
    static func parse(reflog: String, branch: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        for line in reflog.split(separator: "\n") {
            let parts = line.split(separator: "\u{1f}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let date = formatter.date(from: String(parts[0])) else { continue }
            let subject = String(parts[1])
            let prefix = "checkout: moving from "
            guard subject.hasPrefix(prefix) else { continue }
            let move = subject.dropFirst(prefix.count).components(separatedBy: " to ")
            guard move.count == 2 else { continue }
            if move[0] == branch || move[1] == branch { return date }
        }
        return nil
    }
}
