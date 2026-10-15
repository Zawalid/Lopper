import Foundation
import Lopper

/// Everything the app needs from the engine, behind one protocol so the model can be tested with a fake.
protocol EngineClient: Sendable {
    var githubCLIAvailable: Bool { get }
    func scan(settings: Settings) -> AsyncStream<ScanEvent>
    /// `excluding` are folders inside `path` that belong to another worktree and are not counted.
    func measure(_ path: URL, disposable: Set<String>, excluding: [URL]) async -> DiskUsage
    /// Generated folders (node_modules, build output, ...) git ignores inside one working folder.
    func artifacts(in root: URL, repoRoot: URL, location: ArtifactLocation, names: Set<String>) async -> [DiskArtifact]
    /// Tool caches in the home folder (Xcode build data, npm cache, ...), as clearable folders.
    func developerCaches() async -> [DiskArtifact]
    /// Runs the lockfile install that brings a cleared folder back.
    func reinstall(in directory: URL, how: String) async -> Reinstaller.Outcome
    /// Free and total space of the disk the home folder is on.
    func volumeSpace() -> VolumeSpace?
    /// Moves one generated folder to the Trash after re-checking it, recording an undo entry.
    func clearArtifact(_ artifact: DiskArtifact, names: Set<String>, batchID: UUID) async -> CleanOutcome
    /// `strictItemIDs` are worktree items that must be refused if work that exists only in the folder has
    /// appeared since they were reviewed.
    func clean(
        _ items: [CleanupItem], settings: Settings, control: BatchControl, strictItemIDs: Set<String>,
        sizeHints: [String: Int64]
    ) -> AsyncStream<BatchEvent>
    func history() async -> [UndoRecord]
    /// Cleared folders that are still in the Trash.
    func trashedFolders() async -> [UndoRecord]
    /// Deletes exactly these folders from the Trash for good. Nothing else in the Trash is touched.
    func deleteTrashed(_ records: [UndoRecord]) async -> TrashSweeper.Result
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

    func measure(_ path: URL, disposable: Set<String>, excluding: [URL]) async -> DiskUsage {
        await SizeCalculator.measure(path, disposableNames: disposable, excluding: excluding)
    }

    func artifacts(in root: URL, repoRoot: URL, location: ArtifactLocation, names: Set<String>) async -> [DiskArtifact] {
        await ArtifactScanner(git: git).scan(root: root, repoRoot: repoRoot, names: names, location: location)
    }

    func developerCaches() async -> [DiskArtifact] {
        await DeveloperCaches.scan()
    }

    func reinstall(in directory: URL, how: String) async -> Reinstaller.Outcome {
        await Reinstaller().reinstall(in: directory, how: how)
    }

    func volumeSpace() -> VolumeSpace? {
        VolumeSpace.read(at: FileManager.default.homeDirectoryForCurrentUser)
    }

    func clearArtifact(_ artifact: DiskArtifact, names: Set<String>, batchID: UUID) async -> CleanOutcome {
        await ArtifactCleaner(undoLog: undoLog, git: git, gate: gate).clear(artifact, names: names, batchID: batchID)
    }

    func clean(
        _ items: [CleanupItem], settings: Settings, control: BatchControl, strictItemIDs: Set<String>,
        sizeHints: [String: Int64]
    ) -> AsyncStream<BatchEvent> {
        BatchCleaner(cleaner: cleaner(settings)).run(
            items: items, control: control, strictItemIDs: strictItemIDs, sizeHints: sizeHints)
    }

    func history() async -> [UndoRecord] {
        await undoLog.all()
    }

    func trashedFolders() async -> [UndoRecord] {
        TrashSweeper.pending(in: await undoLog.all())
    }

    func deleteTrashed(_ records: [UndoRecord]) async -> TrashSweeper.Result {
        await TrashSweeper(undoLog: undoLog).deleteForGood(records)
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
