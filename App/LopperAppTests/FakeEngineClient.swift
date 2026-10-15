import Foundation
import Lopper
@testable import LopperApp

/// Deterministic engine for model tests: a fixed scan result and scripted clean outcomes.
final class FakeEngineClient: EngineClient, @unchecked Sendable {
    var snapshots: [RepoSnapshot]
    var failures: [URL] = []
    var sizeByPath: [String: Int64] = [:]
    var cleanOutcome: @Sendable (CleanupItem) -> CleanOutcome = { item in
        .removed(UndoRecord(
            timestamp: Fixtures.now, repoPath: "/code/api", action: .deleteBranch, branch: item.id,
            tip: "abc", upstream: nil, worktreePath: nil, trashRef: "refs/lopper/trash/1/x",
            status: .completed))
    }
    private(set) var restoredBatches: [UUID] = []
    private(set) var cleanedItems: [CleanupItem] = []
    let githubCLIAvailable: Bool

    init(snapshots: [RepoSnapshot], githubCLIAvailable: Bool = true) {
        self.snapshots = snapshots
        self.githubCLIAvailable = githubCLIAvailable
    }

    func scan(settings: Settings) -> AsyncStream<ScanEvent> {
        let snapshots = self.snapshots
        let failures = self.failures
        return AsyncStream { continuation in
            continuation.yield(.discovered(count: snapshots.count + failures.count))
            for snapshot in snapshots { continuation.yield(.result(.snapshot(snapshot))) }
            for root in failures { continuation.yield(.result(.failure(repoRoot: root, message: "boom"))) }
            continuation.finish()
        }
    }

    func measure(_ path: URL, disposable: Set<String>) async -> DiskUsage {
        DiskUsage(total: sizeByPath[path.path] ?? 0, disposable: 0)
    }

    func clean(_ items: [CleanupItem], settings: Settings) -> AsyncStream<BatchEvent> {
        cleanedItems = items
        let outcome = cleanOutcome
        let batchID = UUID()
        return AsyncStream { continuation in
            continuation.yield(.started(batchID: batchID, total: items.count))
            var records: [UndoRecord] = []
            var removed = 0, skipped = 0, failed = 0
            for (index, item) in items.enumerated() {
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
                records: records, wasCancelled: false)))
            continuation.finish()
        }
    }

    func history() async -> [UndoRecord] { [] }

    func restoreBatch(_ id: UUID) async -> [RestoreOutcome] {
        restoredBatches.append(id)
        return []
    }

    func restore(_ record: UndoRecord) async -> RestoreOutcome {
        .failed(message: "not used")
    }
}
