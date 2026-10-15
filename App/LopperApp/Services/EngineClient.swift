import Foundation
import Lopper

/// Everything the app needs from the engine, behind one protocol so the model can be tested with a fake.
protocol EngineClient: Sendable {
    var githubCLIAvailable: Bool { get }
    func scan(settings: Settings) -> AsyncStream<ScanEvent>
    func measure(_ path: URL, disposable: Set<String>) async -> DiskUsage
    func clean(_ items: [CleanupItem], settings: Settings, control: BatchControl) -> AsyncStream<BatchEvent>
    func history() async -> [UndoRecord]
    func restoreBatch(_ id: UUID) async -> [RestoreOutcome]
    func restore(_ record: UndoRecord) async -> RestoreOutcome
    func toolStatus() async -> ToolStatus
}

/// The real engine. One shared gate serializes scans and removals per repository.
struct LiveEngineClient: EngineClient {
    private let gate = RepoGate()
    private let undoLog = UndoLog(url: UndoLog.defaultURL)
    private let git = GitRunner()

    var githubCLIAvailable: Bool { GhCliProvider.locate() != nil }

    private func inspector(_ settings: Settings) -> RepoInspector {
        RepoInspector(git: git, settings: settings, prProvider: GhCliProvider())
    }

    private func cleaner(_ settings: Settings) -> Cleaner {
        Cleaner(git: git, inspector: inspector(settings), undoLog: undoLog, gate: gate)
    }

    func scan(settings: Settings) -> AsyncStream<ScanEvent> {
        ScanService(
            inspector: inspector(settings),
            scanner: RepoScanner(excludePatterns: settings.excludePatterns),
            gate: gate
        ).scanStream(roots: settings.roots, maxDepth: settings.scanDepth)
    }

    func measure(_ path: URL, disposable: Set<String>) async -> DiskUsage {
        await SizeCalculator.measure(path, disposableNames: disposable)
    }

    func clean(_ items: [CleanupItem], settings: Settings, control: BatchControl) -> AsyncStream<BatchEvent> {
        BatchCleaner(cleaner: cleaner(settings)).run(items: items, control: control)
    }

    func history() async -> [UndoRecord] {
        await undoLog.all()
    }

    func restoreBatch(_ id: UUID) async -> [RestoreOutcome] {
        await cleaner(Settings()).restoreBatch(id)
    }

    func restore(_ record: UndoRecord) async -> RestoreOutcome {
        await cleaner(Settings()).restore(record)
    }

    func toolStatus() async -> ToolStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let gitOutput = try? await git.run(["--version"], in: home)
        let gitVersion = gitOutput.flatMap { $0.succeeded ? ToolStatus.parseGitVersion($0.stdout) : nil }

        guard let gh = GhCliProvider.locate() else {
            return ToolStatus(gitVersion: gitVersion, gitHubCLI: .notInstalled)
        }
        let output = try? await CommandRunner(executable: gh, timeout: .seconds(10)).run(["--version"])
        let version = output.flatMap { $0.succeeded ? ToolStatus.parseGitHubVersion($0.stdout) : nil } ?? "unknown"
        return ToolStatus(gitVersion: gitVersion, gitHubCLI: .installed(version: version, path: gh.path))
    }
}
