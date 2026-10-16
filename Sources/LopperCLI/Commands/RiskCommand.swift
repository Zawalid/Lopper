import ArgumentParser
import Foundation
import Lopper

struct LocalOnlyJSON: Encodable {
    let kind: String
    let repository: String
    let repositoryPath: String
    let title: String
    let detail: String
    let count: Int
    let lastTouched: String?
    let path: String?
    let branch: String?
    let pushCommand: String?

    init(_ item: LocalOnlyItem) {
        kind = item.kind.rawValue
        repository = item.repoName
        repositoryPath = item.repoRoot.path
        title = item.title
        detail = item.detail
        count = item.count
        lastTouched = item.lastTouched.map(Format.iso8601)
        path = item.path?.path
        branch = item.branch
        pushCommand = item.pushCommand
    }
}

struct RiskPayload: Encodable {
    let total: Int
    let repositories: Int
    let items: [LocalOnlyJSON]
}

struct RiskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "risk",
        abstract: "Work that exists only on this Mac: unpushed commits, uncommitted changes, stashes. Nothing here is ever removed.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let session = try Session.open(options)
        let scan = await session.workspace.scan(measureSizes: false)
        let items = await session.workspace.localOnlyWork(in: scan)
        let repositories = Set(items.map(\.repoRoot)).count

        if options.json {
            let payload = RiskPayload(total: items.count, repositories: repositories, items: items.map(LocalOnlyJSON.init))
            session.console.line(try JSONOutput.string(payload, now: session.now))
            return
        }
        guard !items.isEmpty else {
            session.console.line("Everything in your folders is backed up or merged. Nothing exists only on this Mac.")
            return
        }
        session.console.line(session.style.bold(
            "\(Format.count(items.count, "item")) in \(Format.count(repositories, "repository", "repositories")) exist only on this Mac."))
        var currentRepo: URL?
        for item in items {
            if item.repoRoot != currentRepo {
                currentRepo = item.repoRoot
                session.console.line()
                session.console.line(session.style.bold(item.repoName) + "  " + session.style.dim(item.repoRoot.path))
            }
            let age = item.lastTouched.map { "  " + session.style.dim(Format.age(of: $0, now: session.now)) } ?? ""
            session.console.line("  \(Format.column(item.title, 28)) \(item.detail)\(age)")
            if let command = item.pushCommand, item.kind == .unpushedCommits {
                session.console.line(session.style.dim("    back it up: \(command)"))
            }
        }
    }
}
