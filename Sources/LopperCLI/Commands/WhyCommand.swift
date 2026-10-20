import ArgumentParser
import Foundation
import Lopper

struct WhyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "why", abstract: "Explain the verdict for one branch or worktree, with the exact git evidence.")

    @OptionGroup var options: GlobalOptions

    @Argument(help: "A branch name or a worktree path, or part of one.")
    var name: String

    func run() async throws {
        let session = try Session.open(options)
        let scan = await session.workspace.scan()
        let matches = Self.find(name, in: scan.rows)

        guard let row = matches.first, matches.count == 1 else {
            if matches.isEmpty {
                throw ValidationError("Nothing matches \"\(name)\". `lop list` shows every name.")
            }
            let lines = RowTable.render(matches, style: session.style, now: session.now)
            throw ValidationError(
                "\(matches.count) items match \"\(name)\". Be more specific:\n" + lines.joined(separator: "\n"))
        }

        if options.json {
            session.console.line(try JSONOutput.string(RowJSON(row), now: session.now))
            return
        }
        let style = session.style
        func field(_ label: String, _ value: String) { session.console.line("\(style.dim(Format.column(label, 13))) \(value)") }
        session.console.line(style.bold(row.title) + style.dim("  (\(row.kind == .branch ? "branch" : "worktree") in \(row.repoName))"))
        field("Verdict", style.verdict(row.verdict).trimmingCharacters(in: .whitespaces)
            + (row.isBulkEligible ? "" : style.dim("  (not part of a bulk clean)")))
        field("Evidence", row.evidence)
        for reason in row.reasons { field("", "- \(reason)") }
        if let commit = row.lastCommit {
            field("Last commit", "\(Format.age(of: commit, now: session.now)) ago (\(Format.iso8601(commit).prefix(10)))")
        }
        if let tip = row.facts.tip { field("Tip", String(tip.prefix(10))) }
        if let ahead = row.facts.ahead, let behind = row.facts.behind {
            field("Compared", "\(ahead) ahead, \(behind) behind \(row.facts.defaultBranch ?? "the default branch")")
        }
        if let upstream = row.facts.upstream { field("Upstream", upstream) }
        if let number = row.prNumber { field("Pull request", "#\(number)" + (row.prURL.map { "  \($0.absoluteString)" } ?? "")) }
        else if row.facts.prOffline { field("Pull requests", "not checked (GitHub could not be reached)") }
        else if !row.facts.prDetectionAvailable { field("Pull requests", "not checked (install the GitHub CLI to check them)") }
        if let path = row.path { field("Folder", path.path) }
        if let size = row.size { field("Size", Format.bytes(size)) }
        if row.facts.isDirty { field("Changes", "uncommitted changes in the folder") }
        if !row.extraFiles.isEmpty { field("Extra files", row.extraFiles.joined(separator: ", ")) }
        if let agent = row.agent {
            field("Agent", "\(agent.detection.label), \(agent.state.label)" + (agent.rowNote.map { ". \($0)" } ?? ""))
        }
    }

    /// An exact name wins; otherwise any item whose name or path contains the text.
    static func find(_ query: String, in rows: [CleanupRow]) -> [CleanupRow] {
        let exact = rows.filter { $0.title == query || $0.path?.path == query || $0.id == query }
        if !exact.isEmpty { return exact }
        return rows.filter { "\($0.title) \($0.path?.path ?? "")".localizedCaseInsensitiveContains(query) }
    }
}
