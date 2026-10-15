import Foundation
import Lopper

/// Everything the app needs from the engine, behind one protocol so the model can be tested with a fake.
protocol EngineClient: Sendable {
    var githubCLIAvailable: Bool { get }
    func scan(settings: Settings) -> AsyncStream<ScanEvent>
    func measure(_ path: URL, disposable: Set<String>) async -> DiskUsage
    /// `strictItemIDs` are worktree items that must be refused if work that exists only in the folder has
    /// appeared since they were reviewed.
    func clean(
        _ items: [CleanupItem], settings: Settings, control: BatchControl, strictItemIDs: Set<String>
    ) -> AsyncStream<BatchEvent>
    func history() async -> [UndoRecord]
    func restoreBatch(_ id: UUID) async -> [RestoreOutcome]
    func restore(_ record: UndoRecord) async -> RestoreOutcome
    func toolStatus() async -> ToolStatus
    /// Commits unique to `ref` against `base`, and the size of the change. Read-only and loaded per item.
    func branchHistory(repoRoot: URL, ref: String, base: String?) async -> BranchHistory
    /// When the branch was last switched to or from, from the reflog of `directory`.
    func lastCheckedOut(branch: String, in directory: URL) async -> Date?
    /// The pull request that matters for a branch, nil when none exists or `gh` cannot say.
    func pullRequestStatus(branch: String, repoRoot: URL) async -> PullRequestStatus?
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

    func clean(
        _ items: [CleanupItem], settings: Settings, control: BatchControl, strictItemIDs: Set<String>
    ) -> AsyncStream<BatchEvent> {
        BatchCleaner(cleaner: cleaner(settings)).run(items: items, control: control, strictItemIDs: strictItemIDs)
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

    func branchHistory(repoRoot: URL, ref: String, base: String?) async -> BranchHistory {
        await BranchHistoryReader.read(repoRoot: repoRoot, ref: ref, base: base, git: git)
    }

    func lastCheckedOut(branch: String, in directory: URL) async -> Date? {
        await BranchTouch.lastCheckedOut(branch: branch, in: directory, git: git)
    }

    func pullRequestStatus(branch: String, repoRoot: URL) async -> PullRequestStatus? {
        guard let provider = GhCliProvider() else { return nil }
        return await provider.pullRequestStatus(forBranch: branch, in: repoRoot)
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
