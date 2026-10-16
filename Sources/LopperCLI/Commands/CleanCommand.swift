import ArgumentParser
import Foundation
import Lopper

struct CleanResultJSON: Encodable {
    struct Item: Encodable {
        let id: String
        let title: String
        let outcome: String
        let message: String?
    }

    let batch: String?
    let removed: Int
    let skipped: Int
    let failed: Int
    let freedBytes: Int64
    let items: [Item]
}

struct CleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Show what is safe to remove, ask you to confirm, then remove it. Everything can be undone.")

    @OptionGroup var options: GlobalOptions

    @Flag(name: .long, help: "Show the plan and stop. Nothing is removed.")
    var dryRun = false

    @Flag(name: .shortAndLong, help: "Do not ask for confirmation. Required when not running in a terminal.")
    var yes = false

    @Flag(
        name: .long,
        help: "Also remove items that need a look. Needs a name or --repo, so it can never be a blanket removal.")
    var includeReview = false

    @Option(name: .long, help: "Only this repository (its name or full path).")
    var repo: String?

    @Argument(help: "Only items whose name or path contains this text.")
    var query: String?

    func run() async throws {
        if includeReview && repo == nil && (query ?? "").isEmpty {
            throw ValidationError("--include-review needs a name to remove or --repo, so it cannot sweep everything.")
        }
        let session = try Session.open(options)
        let console = session.console
        let scan = await session.workspace.scan()

        let candidates = RowFilter(repository: repo, query: query).apply(scan.rows)
        let chosen = candidates.filter { $0.isBulkEligible || (includeReview && $0.verdict == .review && $0.isSelectable) }
        let held = candidates.filter { !chosen.contains($0) && $0.verdict != .protected }

        if chosen.isEmpty {
            if options.json {
                console.line(try JSONOutput.string(CleanResultJSON(batch: nil, removed: 0, skipped: 0, failed: 0, freedBytes: 0, items: []), now: session.now))
            } else {
                console.line("Nothing is safe to remove.")
                if !held.isEmpty { console.line(session.style.dim("\(Format.count(held.count, "item")) need a look: `lop list --review`.")) }
            }
            return
        }

        let total = chosen.reduce(0) { $0 + ($1.size ?? 0) }
        if !options.json {
            console.line(session.style.bold("This will remove \(Format.count(chosen.count, "item"))" + (total > 0 ? ", about \(Format.bytes(total))" : "") + ":"))
            RowTable.render(chosen, style: session.style, now: session.now).forEach { console.line($0) }
            console.line(session.style.dim("Branches and worktrees can be restored for \(session.settings.trashRetentionDays) days with `lop undo`."))
            if !held.isEmpty { console.line(session.style.dim("\(Format.count(held.count, "other item")) left alone: `lop list --review`.")) }
        }
        if dryRun {
            if !options.json { console.line("Dry run: nothing was removed.") }
            return
        }

        if !yes {
            guard console.isInteractive, !options.json else {
                throw ValidationError("Refusing to remove without confirmation. Run it in a terminal, or pass --yes.")
            }
            console.line()
            guard console.confirm("Remove these \(Format.count(chosen.count, "item"))?") else {
                console.line("Nothing was removed.")
                return
            }
        }

        var items: [CleanResultJSON.Item] = []
        var summary: BatchSummary?
        for await event in session.workspace.clean(chosen) {
            switch event {
            case .started: break
            case .itemFinished(_, let item, let outcome):
                let title = chosen.first { $0.cleanupItem?.id == item.id }?.title ?? item.id
                switch outcome {
                case .removed:
                    items.append(.init(id: item.id, title: title, outcome: "removed", message: nil))
                    if !options.json { console.line("\(session.style.green("removed"))  \(title)") }
                case .skipped(let reason):
                    items.append(.init(id: item.id, title: title, outcome: "skipped", message: reason))
                    if !options.json { console.line("\(session.style.yellow("skipped"))  \(title): \(reason)") }
                case .failed(let message):
                    items.append(.init(id: item.id, title: title, outcome: "failed", message: message))
                    if !options.json { console.line("\(session.style.red("failed"))   \(title): \(message)") }
                }
            case .finished(let result):
                summary = result
            }
        }

        let freed = summary?.records.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) } ?? 0
        if options.json {
            console.line(try JSONOutput.string(
                CleanResultJSON(
                    batch: summary?.batchID.uuidString, removed: summary?.removed ?? 0, skipped: summary?.skipped ?? 0,
                    failed: summary?.failed ?? 0, freedBytes: freed, items: items),
                now: session.now))
            return
        }
        guard let summary else { return }
        console.line()
        console.line("Removed \(Format.count(summary.removed, "item"))"
            + (summary.skipped > 0 ? ", skipped \(summary.skipped)" : "")
            + (summary.failed > 0 ? ", \(summary.failed) failed" : "") + ".")
        if summary.removed > 0 { console.line(session.style.dim("Undo it all with `lop undo --last`.")) }
        if summary.failed > 0 { throw ExitCode(1) }
    }
}
