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
        if includeReview && repo == nil && (query ?? "").count < 3 {
            throw ValidationError(
                "--include-review needs a name of at least 3 characters, or --repo, so it cannot sweep everything.")
        }
        let session = try Session.open(options)
        try session.requireTrustedSettings()
        let console = session.console
        let scan = await session.workspace.scan()

        let candidates = RowFilter(repository: repo, query: query).apply(scan.rows)
        // Review items are removed only when the name matches the item itself (not just a folder it sits in), and never
        // while an agent may still be using the worktree.
        let needle = query ?? ""
        let chosen = candidates.filter {
            $0.isBulkEligible
                || (includeReview && $0.verdict == .review && $0.isSelectable && $0.agentHeldBackReason == nil
                    && (needle.isEmpty || $0.title.localizedCaseInsensitiveContains(needle)))
        }
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
        try await CleanFlow.execute(session: session, chosen: chosen, held: held, dryRun: dryRun, yes: yes)
    }
}
