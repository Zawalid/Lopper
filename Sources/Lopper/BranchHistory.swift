import Foundation

public struct CommitSummary: Sendable, Equatable, Identifiable {
    public var id: String { hash }
    public let hash: String
    public let subject: String
    public let author: String
    public let date: Date

    public init(hash: String, subject: String, author: String, date: Date) {
        self.hash = hash
        self.subject = subject
        self.author = author
        self.date = date
    }
}

public struct DiffSummary: Sendable, Equatable {
    public let files: Int
    public let insertions: Int
    public let deletions: Int

    public init(files: Int, insertions: Int, deletions: Int) {
        self.files = files
        self.insertions = insertions
        self.deletions = deletions
    }
}

/// What a branch holds that the default branch does not: the commits that would be lost with it, and how big
/// the change is. Read on demand for one item, never during a scan.
public struct BranchHistory: Sendable, Equatable {
    /// The branch the commits were compared against; nil when there was no default branch to compare to.
    public let comparedTo: String?
    /// Newest first, capped at the requested limit.
    public let commits: [CommitSummary]
    /// How many commits there are in total, which can exceed `commits.count`.
    public let totalCommits: Int
    public let diff: DiffSummary?

    public var isTruncated: Bool { totalCommits > commits.count }

    public static let empty = BranchHistory(comparedTo: nil, commits: [], totalCommits: 0, diff: nil)

    public init(comparedTo: String?, commits: [CommitSummary], totalCommits: Int, diff: DiffSummary?) {
        self.comparedTo = comparedTo
        self.commits = commits
        self.totalCommits = totalCommits
        self.diff = diff
    }
}

public enum BranchHistoryReader {
    /// Read-only. Any git failure (a ref that no longer exists, a timeout) yields an empty history rather than
    /// an error, because this only decorates the details panel and must never get in the way of it.
    public static func read(
        repoRoot: URL, ref: String, base: String?, git: GitRunner = GitRunner(), limit: Int = 20
    ) async -> BranchHistory {
        // A name that looks like an option is never a real branch or commit; refuse it instead of passing it on.
        guard !ref.isEmpty, !ref.hasPrefix("-"), base?.hasPrefix("-") != true else { return .empty }

        let range = base.map { "\($0)..\(ref)" } ?? ref
        let format = "--format=%H%x1f%an%x1f%aI%x1f%s%x1e"
        do {
            let log = try await git.runChecked(["log", "-n", String(limit), format, range, "--"], in: repoRoot)
            let count = try await git.runChecked(["rev-list", "--count", range, "--"], in: repoRoot)
            let commits = parseLog(log)
            var diff: DiffSummary?
            if let base {
                let stat = try? await git.runChecked(["diff", "--shortstat", "\(base)...\(ref)", "--"], in: repoRoot)
                diff = stat.flatMap(parseShortstat)
            }
            return BranchHistory(
                comparedTo: base, commits: commits, totalCommits: Int(count) ?? commits.count, diff: diff)
        } catch {
            return .empty
        }
    }

    /// Records are separated by U+001E, fields by U+001F, so subjects containing any printable text are safe.
    static func parseLog(_ text: String) -> [CommitSummary] {
        let formatter = ISO8601DateFormatter()
        return text.split(separator: "\u{1e}").compactMap { record in
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .newlines) }
            guard fields.count == 4, !fields[0].isEmpty, let date = formatter.date(from: fields[2]) else {
                return nil
            }
            return CommitSummary(hash: fields[0], subject: fields[3], author: fields[1], date: date)
        }
    }

    /// " 3 files changed, 12 insertions(+), 4 deletions(-)" with any part possibly missing.
    static func parseShortstat(_ text: String) -> DiffSummary? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        func number(before word: String) -> Int {
            guard let range = line.range(of: word) else { return 0 }
            let prefix = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let digits = prefix.split(separator: " ").last.map(String.init) ?? ""
            return Int(digits) ?? 0
        }
        let files = number(before: "file")
        guard files > 0 else { return nil }
        return DiffSummary(files: files, insertions: number(before: "insertion"), deletions: number(before: "deletion"))
    }
}
