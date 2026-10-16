import ArgumentParser
import Foundation
import Lopper

struct FolderJSON: Encodable {
    let path: String
    let name: String
    let kind: String
    let bytes: Int64
    let repository: String
    let location: String
    let offered: Bool
    let regenerate: String?
    let blockedReason: String?

    init(_ artifact: DiskArtifact) {
        path = artifact.path.path
        name = artifact.name
        kind = artifact.kind.rawValue
        bytes = artifact.bytes
        repository = artifact.repoRoot.lastPathComponent
        switch artifact.location {
        case .mainCheckout: location = "main"
        case .worktree(let branch): location = "worktree:\(branch ?? "detached")"
        case .developerCache: location = "cache"
        }
        switch artifact.removal {
        case .offered(let how): offered = true; regenerate = how; blockedReason = nil
        case .blocked(let why): offered = false; regenerate = nil; blockedReason = why
        }
    }
}

struct DiskPayload: Encodable {
    let clearableBytes: Int64
    let folders: [FolderJSON]
    let caches: [FolderJSON]
}

struct DiskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disk",
        abstract: "Where the space goes: generated folders (node_modules, build output) and developer caches.")

    @OptionGroup var options: GlobalOptions

    @Flag(name: .long, help: "Also list tool caches in your home folder (Xcode build data, the npm cache, ...).")
    var caches = false

    @Flag(name: .long, help: "Clear the generated folders Lopper offers, to the Trash, after you confirm.")
    var clear = false

    @Flag(name: .shortAndLong, help: "With --clear: do not ask for confirmation. Required when not in a terminal.")
    var yes = false

    @Flag(name: .long, help: "With --clear: show the plan and stop.")
    var dryRun = false

    @Option(name: .long, help: "Only this repository (its name or full path).")
    var repo: String?

    @Option(name: .long, help: "Only folders in projects nobody has edited for this many days.")
    var untouchedDays: Int?

    @Option(name: .shortAndLong, help: "How many of the largest folders to list.")
    var limit = 15

    func run() async throws {
        let session = try Session.open(options)
        let console = session.console
        let scan = await session.workspace.scan(measureSizes: false)
        var folders = await session.workspace.artifacts(for: scan)
        if let repo {
            folders = folders.filter {
                $0.repoRoot.lastPathComponent.localizedCaseInsensitiveCompare(repo) == .orderedSame || $0.repoRoot.path == repo
            }
        }
        if let days = untouchedDays {
            let cutoff = session.now.addingTimeInterval(-TimeInterval(days) * 86_400)
            folders = folders.filter { ($0.newestModification ?? .distantPast) < cutoff }
        }
        let offered = folders.filter { $0.removal.isOffered }
        let clearable = offered.reduce(Int64(0)) { $0 + $1.bytes }
        let cacheFolders = caches ? await session.workspace.developerCaches() : []

        if clear { try await performClear(session: session, offered: offered, clearable: clearable); return }

        if options.json {
            console.line(try JSONOutput.string(
                DiskPayload(clearableBytes: clearable, folders: folders.map(FolderJSON.init), caches: cacheFolders.map(FolderJSON.init)),
                now: session.now))
            return
        }
        if folders.isEmpty && cacheFolders.isEmpty {
            console.line("No generated folders found.")
            return
        }
        for artifact in folders.prefix(max(limit, 1)) {
            let place: String
            switch artifact.location {
            case .mainCheckout: place = artifact.repoRoot.lastPathComponent
            case .worktree(let branch): place = "\(artifact.repoRoot.lastPathComponent) / \(branch ?? "detached")"
            case .developerCache: place = "cache"
            }
            let note = artifact.removal.isOffered ? "" : session.style.dim("  not offered")
            console.line("\(Format.column(Format.bytes(artifact.bytes), 10)) \(Format.column(artifact.name, 16)) \(place)\(note)")
        }
        if folders.count > limit { console.line(session.style.dim("... and \(folders.count - limit) more. Use --limit or --json.")) }
        for cache in cacheFolders {
            console.line("\(Format.column(Format.bytes(cache.bytes), 10)) \(Format.column(cache.name, 16)) \(session.style.dim("developer cache"))")
        }
        console.line()
        console.line("\(Format.count(offered.count, "folder")), \(Format.bytes(clearable)) can be cleared. "
            + session.style.dim("`lop disk --clear` moves them to the Trash."))
    }

    private func performClear(session: Session, offered: [DiskArtifact], clearable: Int64) async throws {
        let console = session.console
        if offered.isEmpty {
            console.line(options.json ? "{}" : "Nothing to clear.")
            return
        }
        if !options.json {
            console.line(session.style.bold("This will move \(Format.count(offered.count, "folder")) to the Trash, \(Format.bytes(clearable)):"))
            for artifact in offered.prefix(20) {
                console.line("  \(Format.column(Format.bytes(artifact.bytes), 10)) \(artifact.path.path)")
            }
            if offered.count > 20 { console.line("  ... and \(offered.count - 20) more") }
            console.line(session.style.dim("They are checked again right before moving. `lop undo --last` puts them back."))
        }
        if dryRun {
            if !options.json { console.line("Dry run: nothing was moved.") }
            return
        }
        if !yes {
            guard console.isInteractive, !options.json else {
                throw ValidationError("Refusing to clear without confirmation. Run it in a terminal, or pass --yes.")
            }
            console.line()
            guard console.confirm("Move these \(Format.count(offered.count, "folder")) to the Trash?") else {
                console.line("Nothing was moved.")
                return
            }
        }
        let outcomes = await session.workspace.clear(offered)
        var moved = 0, skipped = 0, failed = 0
        var freed: Int64 = 0
        for (artifact, outcome) in zip(offered, outcomes) {
            switch outcome {
            case .removed(let record):
                moved += 1
                freed += record.bytes ?? artifact.bytes
                if !options.json { console.line("\(session.style.green("moved"))    \(artifact.path.path)") }
            case .skipped(let reason):
                skipped += 1
                if !options.json { console.line("\(session.style.yellow("skipped"))  \(artifact.path.path): \(reason)") }
            case .failed(let message):
                failed += 1
                if !options.json { console.line("\(session.style.red("failed"))   \(artifact.path.path): \(message)") }
            }
        }
        if options.json {
            console.line(try JSONOutput.string(
                ["moved": moved, "skipped": skipped, "failed": failed, "freedBytes": Int(freed)], now: session.now))
            return
        }
        console.line()
        console.line("Moved \(Format.count(moved, "folder")) to the Trash, \(Format.bytes(freed))"
            + (skipped > 0 ? ", skipped \(skipped)" : "") + (failed > 0 ? ", \(failed) failed" : "") + ".")
        if failed > 0 { throw ExitCode(1) }
    }
}
