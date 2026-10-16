import ArgumentParser
import Foundation
import Lopper

struct HistoryEntryJSON: Encodable {
    let id: String
    let batch: String?
    let timestamp: String
    let action: String
    let name: String
    let repository: String
    let status: String
    let reason: String?
    let bytes: Int64?
    let daysLeft: Int?
}

enum HistoryFormat {
    static func name(_ record: UndoRecord) -> String {
        switch record.action {
        case .deleteBranch: record.branch ?? "(branch)"
        case .removeWorktree: record.branch ?? URL(fileURLWithPath: record.worktreePath ?? "").lastPathComponent
        case .trashFolder: URL(fileURLWithPath: record.worktreePath ?? record.trashedPath ?? "").lastPathComponent
        }
    }

    static func actionLabel(_ action: UndoAction) -> String {
        switch action {
        case .deleteBranch: "branch"
        case .removeWorktree: "worktree"
        case .trashFolder: "folder"
        }
    }

    static func daysLeft(_ record: UndoRecord, retentionDays: Int, now: Date) -> Int? {
        guard record.status == .completed else { return nil }
        let used = Int(now.timeIntervalSince(record.timestamp) / 86_400)
        return max(retentionDays - used, 0)
    }

    static func shortID(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }
}

struct HistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history", abstract: "List what Lopper removed, newest first, and how long each can be restored.")

    @OptionGroup var options: GlobalOptions

    @Option(name: .shortAndLong, help: "How many entries to show.")
    var limit = 20

    func run() async throws {
        let session = try Session.open(options, requireFolders: false)
        let records = await session.workspace.history()
            .sorted { $0.timestamp > $1.timestamp }
        let shown = Array(records.prefix(max(limit, 1)))
        let retention = session.settings.trashRetentionDays

        if options.json {
            let entries = shown.map { record in
                HistoryEntryJSON(
                    id: record.id.uuidString.lowercased(), batch: record.batchID?.uuidString.lowercased(),
                    timestamp: Format.iso8601(record.timestamp), action: HistoryFormat.actionLabel(record.action),
                    name: HistoryFormat.name(record), repository: URL(fileURLWithPath: record.repoPath).lastPathComponent,
                    status: record.status.rawValue, reason: record.reason, bytes: record.bytes,
                    daysLeft: HistoryFormat.daysLeft(record, retentionDays: retention, now: session.now))
            }
            session.console.line(try JSONOutput.string(["entries": entries], now: session.now))
            return
        }
        if shown.isEmpty {
            session.console.line("Nothing has been removed yet.")
            return
        }
        let nameWidth = min(max(shown.map { HistoryFormat.name($0).count }.max() ?? 4, 4), 40)
        for record in shown {
            let left = HistoryFormat.daysLeft(record, retentionDays: retention, now: session.now)
                .map { "\($0)d left" } ?? record.status.rawValue
            let size = record.bytes.map { Format.bytes($0) } ?? ""
            session.console.line([
                session.style.dim(HistoryFormat.shortID(record.id)),
                Format.column(Format.iso8601(record.timestamp).prefix(10).description, 10),
                Format.column(HistoryFormat.actionLabel(record.action), 8),
                Format.column(HistoryFormat.name(record), nameWidth),
                Format.column(URL(fileURLWithPath: record.repoPath).lastPathComponent, 16),
                Format.column(left, 10), size,
            ].joined(separator: " "))
        }
        session.console.line()
        session.console.line(session.style.dim("Restore one with `lop undo <id>`, or the latest cleanup with `lop undo --last`."))
    }
}

struct UndoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "undo", abstract: "Restore something Lopper removed: one entry by its id, or the latest cleanup.")

    @OptionGroup var options: GlobalOptions

    @Flag(name: .long, help: "Restore the whole latest cleanup.")
    var last = false

    @Argument(help: "The id (or the start of it) shown by `lop history`.")
    var id: String?

    func run() async throws {
        let session = try Session.open(options, requireFolders: false)
        let history = await session.workspace.history().sorted { $0.timestamp > $1.timestamp }
        let console = session.console

        var outcomes: [(String, RestoreOutcome)] = []
        if last {
            guard let latest = history.first(where: { $0.status == .completed }) else {
                throw ValidationError("There is nothing to restore.")
            }
            if let batch = latest.batchID {
                let members = history.filter { $0.batchID == batch && $0.status == .completed }
                // The engine restores branches first, then worktrees, then folders; the names must line up with that
                // order or a failure would be reported against the wrong item.
                let ordered = [UndoAction.deleteBranch, .removeWorktree, .trashFolder].flatMap { action in
                    members.filter { $0.action == action }
                }
                let results = await session.workspace.restoreBatch(batch)
                outcomes = zip(ordered.map(HistoryFormat.name), results).map { ($0, $1) }
            } else {
                outcomes = [(HistoryFormat.name(latest), await session.workspace.restore(latest))]
            }
        } else if let id {
            let prefix = id.lowercased()
            let matches = history.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
            guard prefix.count >= 4, let record = matches.first, matches.count == 1 else {
                throw ValidationError(matches.isEmpty
                    ? "No entry starts with \"\(id)\". `lop history` lists them."
                    : "\"\(id)\" matches \(matches.count) entries. Use more of the id.")
            }
            outcomes = [(HistoryFormat.name(record), await session.workspace.restore(record))]
        } else {
            throw ValidationError("Say what to restore: an id from `lop history`, or --last.")
        }

        var failed = 0
        for (name, outcome) in outcomes {
            switch outcome {
            case .restored: console.line("\(session.style.green("restored"))  \(name)")
            case .failed(let message):
                failed += 1
                console.line("\(session.style.red("failed"))    \(name): \(message)")
            }
        }
        if failed > 0 { throw ExitCode(1) }
    }
}
