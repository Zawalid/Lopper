import ArgumentParser
import Foundation
import Lopper

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "List branches and worktrees with their verdict and the evidence behind it.")

    @OptionGroup var options: GlobalOptions

    @Flag(name: .long, help: "Only items that are safe to remove.")
    var safe = false

    @Flag(name: .long, help: "Only items that need a look.")
    var review = false

    @Flag(name: .long, help: "Only protected items.")
    var protectedOnly = false

    @Option(name: .long, help: "Only this repository (its name or full path).")
    var repo: String?

    @Argument(help: "Only items whose name or path contains this text.")
    var query: String?

    func run() async throws {
        let session = try Session.open(options)
        let scan = await session.workspace.scan()
        var filter = RowFilter(repository: repo, query: query)
        if safe { filter.verdicts.insert(.safe) }
        if review { filter.verdicts.insert(.review) }
        if protectedOnly { filter.verdicts.insert(.protected) }
        let rows = filter.apply(scan.rows)

        if options.json {
            session.console.line(try JSONOutput.string(["rows": rows.map(RowJSON.init)], now: session.now))
            return
        }
        for failure in scan.failures {
            session.console.errorLine("\(failure.root.path): \(failure.message)")
        }
        if rows.isEmpty {
            session.console.line("Nothing matches.")
            return
        }
        RowTable.render(rows, style: session.style, now: session.now).forEach { session.console.line($0) }
        session.console.line()
        let bulk = rows.filter(\.isBulkEligible).count
        session.console.line("\(Format.count(rows.count, "item")), \(bulk) safe to remove. `lop why <name>` shows the evidence.")
    }
}
