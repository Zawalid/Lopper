#if DEBUG
// A scripted engine for previews and tests. Compiled into debug builds only.
import Foundation
import Lopper

/// Deterministic engine for model tests: a fixed scan result and scripted clean outcomes.
final class FakeEngineClient: EngineClient, @unchecked Sendable {
    var snapshots: [RepoSnapshot]
    var failures: [URL] = []
    var sizeByPath: [String: Int64] = [:]
    var activityByPath: [String: Date] = [:]
    var cleanOutcome: @Sendable (CleanupItem) -> CleanOutcome = { item in
        .removed(UndoRecord(
            timestamp: Fixtures.now, repoPath: "/code/api", action: .deleteBranch, branch: item.id,
            tip: "abc", upstream: nil, worktreePath: nil, trashRef: "refs/lopper/trash/1/x",
            status: .completed))
    }
    /// Like the real batch cleaner: a worktree that carries its branch is followed by a second event for the
    /// branch deletion, so one selected row produces two events.
    var emitsBranchFollowUps = false
    var scanDelay: Duration = .zero
    var cleanItemDelay: Duration = .zero
    var restoreBatchOutcomes: [RestoreOutcome] = []
    var tools = ToolStatus(
        gitVersion: "2.54.0 (Apple Git-157)",
        gitHubCLI: .installed(version: "2.98.0", path: "/opt/homebrew/bin/gh"))
    /// Scripted histories keyed by the ref that is asked for (the row's commit hash).
    var histories: [String: BranchHistory] = [:]
    private(set) var historyRequests = 0
    private(set) var lastSizeHints: [String: Int64] = [:]
    private(set) var restoredRecords: [UndoRecord] = []
    var checkouts: [String: Date] = [:]
    var pullRequests: [String: PullRequestStatus] = [:]
    private(set) var checkoutRequests = 0
    private(set) var pullRequestRequests = 0
    private(set) var restoredBatches: [UUID] = []
    private(set) var cleanedItems: [CleanupItem] = []
    private(set) var strictItemIDs: Set<String> = []
    let githubCLIAvailable: Bool

    init(snapshots: [RepoSnapshot], githubCLIAvailable: Bool = true) {
        self.snapshots = snapshots
        self.githubCLIAvailable = githubCLIAvailable
    }

    func scan(settings: Settings) -> AsyncStream<ScanEvent> {
        let snapshots = self.snapshots
        let failures = self.failures
        let delay = scanDelay
        return AsyncStream { continuation in
            let task = Task {
                if delay > .zero { try? await Task.sleep(for: delay) }
                if Task.isCancelled { continuation.finish(); return }
                continuation.yield(.discovered(count: snapshots.count + failures.count))
                for snapshot in snapshots { continuation.yield(.result(.snapshot(snapshot))) }
                for root in failures { continuation.yield(.result(.failure(repoRoot: root, message: "boom"))) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private let measureLock = NSLock()
    private var measurementLog: [(path: String, excluding: [String])] = []
    /// Every folder that was measured, with what was left out of the count.
    var measurements: [(path: String, excluding: [String])] {
        measureLock.withLock { measurementLog }
    }

    var suggestions: [FolderSuggestion] = []
    var systemScanEvents: [SystemScanEvent] = []
    /// When true the scripted scan never finishes, so a test can stop it midway.
    var systemScanHangs = false

    func folderSuggestions() async -> [FolderSuggestion] { suggestions }

    func systemScan() -> AsyncStream<SystemScanEvent> {
        let events = systemScanEvents
        let hangs = systemScanHangs
        return AsyncStream { continuation in
            let task = Task {
                for event in events { continuation.yield(event) }
                if hangs { try? await Task.sleep(for: .seconds(60)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    var reinstallOutcome: Reinstaller.Outcome = .done
    private(set) var reinstalls: [String] = []

    func reinstall(in directory: URL, how: String) async -> Reinstaller.Outcome {
        measureLock.withLock { reinstalls.append("\(how) in \(directory.path)") }
        return reinstallOutcome
    }

    var caches: [DiskArtifact] = []
    var volume: VolumeSpace?

    func developerCaches() async -> [DiskArtifact] { caches }
    func volumeSpace() -> VolumeSpace? { volume }

    /// Scripted: what is "still in the Trash".
    var trashed: [UndoRecord] = []
    private(set) var deletedForGood: [UndoRecord] = []

    func trashedFolders() async -> [UndoRecord] { trashed }

    func deleteTrashed(_ records: [UndoRecord]) async -> TrashSweeper.Result {
        deletedForGood = records
        let ids = Set(records.map(\.id))
        trashed.removeAll { ids.contains($0.id) }
        return TrashSweeper.Result(deleted: records, failures: [])
    }

    func measure(_ path: URL, disposable: Set<String>, excluding: [URL]) async -> DiskUsage {
        measureLock.withLock { measurementLog.append((path.path, excluding.map(\.path))) }
        return DiskUsage(
            total: sizeByPath[path.path] ?? 0, disposable: 0, newestModification: activityByPath[path.path])
    }

    /// Scripted generated folders keyed by the working folder they sit in.
    var artifactsByRoot: [String: [DiskArtifact]] = [:]
    private var artifactScanLog: [String] = []
    private var clearedLog: [DiskArtifact] = []
    /// The working folders that were searched. Scans run a few at a time, so the log is locked.
    var artifactScans: [String] { measureLock.withLock { artifactScanLog } }
    var clearedArtifacts: [DiskArtifact] { measureLock.withLock { clearedLog } }
    var clearArtifactOutcome: @Sendable (DiskArtifact) -> CleanOutcome = { artifact in
        .removed(UndoRecord(
            timestamp: Fixtures.now, repoPath: artifact.repoRoot.path, action: .trashFolder, branch: nil,
            tip: "", upstream: nil, worktreePath: artifact.path.path, trashRef: "", status: .completed,
            reason: artifact.kind.title, bytes: artifact.bytes, trashedPath: "/Users/me/.Trash/\(artifact.name)"))
    }

    func artifacts(in root: URL, repoRoot: URL, location: ArtifactLocation, names: Set<String>) async -> [DiskArtifact] {
        measureLock.withLock { artifactScanLog.append(root.path) }
        return artifactsByRoot[root.path] ?? []
    }

    func clearArtifact(_ artifact: DiskArtifact, names: Set<String>, batchID: UUID) async -> CleanOutcome {
        measureLock.withLock { clearedLog.append(artifact) }
        return clearArtifactOutcome(artifact)
    }

    func clean(
        _ items: [CleanupItem], settings: Settings, control: BatchControl, strictItemIDs: Set<String>,
        sizeHints: [String: Int64]
    ) -> AsyncStream<BatchEvent> {
        cleanedItems = items
        lastSizeHints = sizeHints
        self.strictItemIDs = strictItemIDs
        let outcome = cleanOutcome
        let emits = emitsBranchFollowUps
        let delay = cleanItemDelay
        let batchID = UUID()
        return AsyncStream { continuation in
            let task = Task {
                let followUps = emits ? items.compactMap { item -> CleanupItem? in
                    if case .worktree(let repo, _, let approved, let branch?) = item {
                        return .branch(repoRoot: repo, name: branch, approved: approved)
                    }
                    return nil
                } : []
                continuation.yield(.started(batchID: batchID, total: items.count + followUps.count))
                var records: [UndoRecord] = []
                var removed = 0, skipped = 0, failed = 0
                var stopped = false
                for (index, item) in items.enumerated() {
                    if control.isStopRequested { stopped = true; break }
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    let result = outcome(item)
                    switch result {
                    case .removed(let record): removed += 1; records.append(record)
                    case .skipped: skipped += 1
                    case .failed: failed += 1
                    }
                    continuation.yield(.itemFinished(index: index, item: item, outcome: result))
                }
                for (offset, followUp) in followUps.enumerated() where !stopped {
                    let result = outcome(followUp)
                    if case .removed(let record) = result { removed += 1; records.append(record) }
                    continuation.yield(.itemFinished(index: items.count + offset, item: followUp, outcome: result))
                }
                continuation.yield(.finished(BatchSummary(
                    batchID: batchID, removed: removed, skipped: skipped, failed: failed,
                    records: records, wasCancelled: stopped)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// What `history()` returns, so a preview or test can show a log that survives the startup rescan.
    var historyRecords: [UndoRecord] = []

    func history() async -> [UndoRecord] { historyRecords }

    func restoreBatch(_ id: UUID) async -> [RestoreOutcome] {
        restoredBatches.append(id)
        return restoreBatchOutcomes
    }

    func restore(_ record: UndoRecord) async -> RestoreOutcome {
        restoredRecords.append(record)
        var restored = record
        restored.status = .restored
        return .restored(restored)
    }

    func toolStatus() async -> ToolStatus { tools }

    private(set) var diagnostics: [DiagnosticEvent] = []

    func recordDiagnostic(_ event: DiagnosticEvent) async { diagnostics.append(event) }

    func diagnosticEvents() async -> [DiagnosticEvent] { diagnostics }

    var localOnly: [LocalOnlyItem] = []
    private(set) var localOnlyRequests = 0

    func localOnlyWork(for snapshots: [RepoSnapshot]) async -> [LocalOnlyItem] {
        localOnlyRequests += 1
        return localOnly
    }

    /// Folders listed here are reported with this access; every other folder reads fine.
    var folderAccessOverrides: [String: FolderAccess] = [:]

    func folderAccess(of folders: [URL]) async -> [String: FolderAccess] {
        Dictionary(
            folders.map { ($0.canonicalized.path, folderAccessOverrides[$0.canonicalized.path] ?? .ok) },
            uniquingKeysWith: { first, _ in first })
    }

    func branchHistory(repoRoot: URL, ref: String, base: String?) async -> BranchHistory {
        historyRequests += 1
        return histories[ref] ?? .empty
    }

    func lastCheckedOut(branch: String, in directory: URL) async -> Date? {
        checkoutRequests += 1
        return checkouts[branch]
    }

    func pullRequestStatus(branch: String, repoRoot: URL) async -> PullRequestStatus? {
        pullRequestRequests += 1
        return pullRequests[branch]
    }
}
#endif
