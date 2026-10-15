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
    var scanDelay: Duration = .zero
    var cleanItemDelay: Duration = .zero
    var restoreBatchOutcomes: [RestoreOutcome] = []
    var tools = ToolStatus(
        gitVersion: "2.54.0 (Apple Git-157)",
        gitHubCLI: .installed(version: "2.98.0", path: "/opt/homebrew/bin/gh"))
    /// Scripted histories keyed by the ref that is asked for (the row's commit hash).
    var histories: [String: BranchHistory] = [:]
    private(set) var historyRequests = 0
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

    func measure(_ path: URL, disposable: Set<String>) async -> DiskUsage {
        DiskUsage(
            total: sizeByPath[path.path] ?? 0, disposable: 0, newestModification: activityByPath[path.path])
    }

    func clean(
        _ items: [CleanupItem], settings: Settings, control: BatchControl, strictItemIDs: Set<String>
    ) -> AsyncStream<BatchEvent> {
        cleanedItems = items
        self.strictItemIDs = strictItemIDs
        let outcome = cleanOutcome
        let delay = cleanItemDelay
        let batchID = UUID()
        return AsyncStream { continuation in
            let task = Task {
                continuation.yield(.started(batchID: batchID, total: items.count))
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
                continuation.yield(.finished(BatchSummary(
                    batchID: batchID, removed: removed, skipped: skipped, failed: failed,
                    records: records, wasCancelled: stopped)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func history() async -> [UndoRecord] { [] }

    func restoreBatch(_ id: UUID) async -> [RestoreOutcome] {
        restoredBatches.append(id)
        return restoreBatchOutcomes
    }

    func restore(_ record: UndoRecord) async -> RestoreOutcome {
        .failed(message: "not used")
    }

    func toolStatus() async -> ToolStatus { tools }

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
