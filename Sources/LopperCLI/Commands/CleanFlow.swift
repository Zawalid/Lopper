import ArgumentParser
import Foundation
import Lopper

/// Shows a plan, asks for confirmation, removes, reports. Shared by `clean` and `agents --reclaim-finished`, so both
/// confirm and report the same way and neither can remove anything without the same safeguards.
enum CleanFlow {
    static func execute(
        session: Session, chosen: [CleanupRow], held: [CleanupRow], dryRun: Bool, yes: Bool
    ) async throws {
        let options = session.options
        let console = session.console
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
