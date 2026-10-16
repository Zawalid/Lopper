import Foundation
import Lopper

/// Which rows a command is about: the verdict filter and the narrowing options shared by `list`, `clean`, `agents`.
struct RowFilter {
    var verdicts: Set<VerdictKind> = []
    var repository: String?
    var agentsOnly = false
    var query: String?

    func apply(_ rows: [CleanupRow]) -> [CleanupRow] {
        rows.filter { row in
            if !verdicts.isEmpty && !verdicts.contains(row.verdict) { return false }
            if agentsOnly && row.agent == nil { return false }
            if let repository, row.repoName.localizedCaseInsensitiveCompare(repository) != .orderedSame,
               row.repoRoot.path != repository { return false }
            if let query, !query.isEmpty {
                let haystack = "\(row.title) \(row.path?.path ?? "")"
                if !haystack.localizedCaseInsensitiveContains(query) { return false }
            }
            return true
        }
    }
}

enum RowTable {
    /// One line per row: verdict, kind, name, repository, age, size and the reason.
    static func render(_ rows: [CleanupRow], style: Style, now: Date) -> [String] {
        let titleWidth = min(max(rows.map(\.title.count).max() ?? 4, 4), 44)
        let repoWidth = min(max(rows.map(\.repoName.count).max() ?? 4, 4), 22)
        return rows.map { row in
            let kind = row.kind == .branch ? "branch  " : "worktree"
            let size = row.size.map { Format.bytes($0) } ?? ""
            let note = row.agent?.rowNote ?? row.evidence
            let tool = row.agent.map { " [\($0.detection.tool.label)]" } ?? ""
            return [
                style.verdict(row.verdict), kind, Format.column(row.title, titleWidth),
                Format.column(row.repoName, repoWidth), Format.column(Format.age(of: row.lastCommit, now: now), 6),
                Format.column(size, 9), note + tool,
            ].joined(separator: " ")
        }
    }
}
