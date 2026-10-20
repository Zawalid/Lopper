import Foundation
import Lopper

/// Everything the app needs from the engine, behind one protocol so the model can be tested with a fake.
protocol EngineClient: Sendable {
    var githubCLIAvailable: Bool { get }
    func scan(settings: Settings) -> AsyncStream<ScanEvent>
    /// Reads only these repositories, to refresh them after a removal or a restore without scanning everything.
    func scanRepositories(_ roots: [URL], settings: Settings) async -> [RepoScanResult]
    /// `excluding` are folders inside `path` that belong to another worktree and are not counted.
    func measure(_ path: URL, disposable: Set<String>, excluding: [URL]) async -> DiskUsage
    /// Generated folders (node_modules, build output, ...) git ignores inside one working folder.
    func artifacts(in root: URL, repoRoot: URL, location: ArtifactLocation, names: Set<String>) async -> [DiskArtifact]
    /// Tool caches in the home folder (Xcode build data, npm cache, ...), as clearable folders.
    func developerCaches() async -> [DiskArtifact]
    /// The usual project folders that exist on this Mac, with how many repositories each holds.
    func folderSuggestions() async -> [FolderSuggestion]
    /// Looks through the home folder for repositories. Read only; ends with the folders that hold them.
    func systemScan() -> AsyncStream<SystemScanEvent>
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
    /// The files that stand in the way of removing this worktree's folder. Reads git; changes nothing.
    func blockingChanges(of row: CleanupRow) async -> WorktreeChanges
    /// Moves one worktree's whole folder to the Trash and drops git's record of it, keeping the branch. Refuses
    /// branches, Protected rows and worktrees an agent may still be using.
    func removeKeepingCopy(_ row: CleanupRow, settings: Settings) async -> CleanOutcome
    func history() async -> [UndoRecord]
    /// Cleared folders that are still in the Trash.
    func trashedFolders() async -> [UndoRecord]
    /// Deletes exactly these folders from the Trash for good. Nothing else in the Trash is touched.
    func deleteTrashed(_ records: [UndoRecord]) async -> TrashSweeper.Result
    func restoreBatch(_ id: UUID) async -> [RestoreOutcome]
    func restore(_ record: UndoRecord) async -> RestoreOutcome
    func toolStatus() async -> ToolStatus
    /// Adds to the local diagnostics log. It never leaves this Mac.
    func recordDiagnostic(_ event: DiagnosticEvent) async
    func diagnosticEvents() async -> [DiagnosticEvent]
    /// Work in these repositories that exists only on this Mac. Reads git; changes nothing.
    func localOnlyWork(for snapshots: [RepoSnapshot]) async -> [LocalOnlyItem]
    /// The commits or files inside one item, read when its row is opened. Reads git; changes nothing.
    func localOnlyDetail(for item: LocalOnlyItem) async -> LocalOnlyDetail
    /// Whether each folder can be read, keyed by canonical path. Opens the folders, so it can wait on a slow drive.
    func folderAccess(of folders: [URL]) async -> [String: FolderAccess]
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
    private let diagnostics = DiagnosticLog(url: DiagnosticLog.defaultURL)

    var githubCLIAvailable: Bool { GhCliProvider.locate() != nil }

    private func inspector(_ settings: Settings) -> RepoInspector {
        RepoInspector(git: git, settings: settings, prProvider: GhCliProvider())
    }

    private func cleaner(_ settings: Settings) -> Cleaner {
        Cleaner(git: git, inspector: inspector(settings), undoLog: undoLog, gate: gate)
    }

    func scan(settings: Settings) -> AsyncStream<ScanEvent> {
        // A scan a person asked for always tries GitHub again, so coming back online is noticed straight away.
        GitHubReachability.shared.reset()
        return ScanService(
            inspector: inspector(settings),
            scanner: RepoScanner(excludePatterns: settings.excludePatterns),
            gate: gate
        ).scanStream(roots: settings.roots, maxDepth: settings.scanDepth)
    }

    func scanRepositories(_ roots: [URL], settings: Settings) async -> [RepoScanResult] {
        let inspector = inspector(settings)
        return await ScanService(
            inspector: inspector, scanner: RepoScanner(excludePatterns: settings.excludePatterns), gate: gate
        ).inspect(repos: roots.filter { !inspector.isIgnored($0) })
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

    func folderSuggestions() async -> [FolderSuggestion] {
        await FolderSuggestions.find()
    }

    func systemScan() -> AsyncStream<SystemScanEvent> {
        SystemScanner().scan(home: FileManager.default.homeDirectoryForCurrentUser)
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

    func blockingChanges(of row: CleanupRow) async -> WorktreeChanges {
        guard row.kind == .worktree, let path = row.path else { return .none }
        return await WorktreeChanges.read(at: path, git: git)
    }

    func removeKeepingCopy(_ row: CleanupRow, settings: Settings) async -> CleanOutcome {
        if let refusal = row.keepCopyRefusal { return .skipped(reason: refusal) }
        guard let path = row.path else { return .skipped(reason: "Only a worktree's folder can be moved to the Trash") }
        return await cleaner(settings).removeWorktreeKeepingCopy(
            repoRoot: row.repoRoot, path: path, approved: row.verdict, batchID: UUID(), bytes: nil)
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

    func localOnlyWork(for snapshots: [RepoSnapshot]) async -> [LocalOnlyItem] {
        await LocalWorkScanner(git: git).scan(snapshots)
    }

    func localOnlyDetail(for item: LocalOnlyItem) async -> LocalOnlyDetail {
        await LocalWorkScanner(git: git).detail(for: item)
    }

    func folderAccess(of folders: [URL]) async -> [String: FolderAccess] {
        await Task.detached(priority: .utility) { FolderProbe.check(folders) }.value
    }

    func recordDiagnostic(_ event: DiagnosticEvent) async { await diagnostics.record(event) }

    func diagnosticEvents() async -> [DiagnosticEvent] { await diagnostics.events() }

    func toolStatus() async -> ToolStatus {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Without the command line tools /usr/bin/git is a stub that opens Apple's installer, so never run it then.
        let gitOutput = GitAvailability.isInstalled() ? try? await git.run(["--version"], in: home) : nil
        let gitVersion = gitOutput.flatMap { $0.succeeded ? ToolStatus.parseGitVersion($0.stdout) : nil }

        guard let gh = GhCliProvider.locate() else {
            return ToolStatus(gitVersion: gitVersion, gitHubCLI: .notInstalled)
        }
        let output = try? await CommandRunner(executable: gh, timeout: .seconds(10)).run(["--version"])
        let version = output.flatMap { $0.succeeded ? ToolStatus.parseGitHubVersion($0.stdout) : nil } ?? "unknown"
        return ToolStatus(gitVersion: gitVersion, gitHubCLI: .installed(version: version, path: gh.path))
    }
}
