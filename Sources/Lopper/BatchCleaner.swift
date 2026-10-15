import Foundation
import os

/// One thing the user asked to remove.
public enum CleanupItem: Sendable, Equatable, Identifiable {
    case branch(repoRoot: URL, name: String, approved: VerdictKind)
    /// A worktree and, when `deleteBranch` is set, its branch afterwards (a "bundle"). The branch is
    /// protected while the worktree has it checked out, so the order is what makes bundles work.
    case worktree(repoRoot: URL, path: URL, approved: VerdictKind, deleteBranch: String?)

    public var id: String {
        switch self {
        case .branch(let repoRoot, let name, _): "branch:\(repoRoot.path)#\(name)"
        case .worktree(_, let path, _, _): "worktree:\(path.path)"
        }
    }
}

public struct BatchSummary: Sendable, Equatable {
    public let batchID: UUID
    public let removed: Int
    public let skipped: Int
    public let failed: Int
    /// Records of everything that was removed, in execution order.
    public let records: [UndoRecord]
    public let wasCancelled: Bool

    public init(batchID: UUID, removed: Int, skipped: Int, failed: Int, records: [UndoRecord], wasCancelled: Bool) {
        self.batchID = batchID
        self.removed = removed
        self.skipped = skipped
        self.failed = failed
        self.records = records
        self.wasCancelled = wasCancelled
    }
}

public enum BatchEvent: Sendable, Equatable {
    /// `total` is an upper bound: steps whose precondition fails (a worktree that could not be removed)
    /// never run their dependent branch deletion.
    case started(batchID: UUID, total: Int)
    case itemFinished(index: Int, item: CleanupItem, outcome: CleanOutcome)
    case finished(BatchSummary)
}

/// A cooperative stop signal. Unlike cancelling the consuming task, it never interrupts the item that is
/// being removed: the batch finishes that item, then stops, and still delivers `.finished`.
public final class BatchControl: Sendable {
    private let stopRequested = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public func requestStop() {
        stopRequested.withLock { $0 = true }
    }

    public var isStopRequested: Bool {
        stopRequested.withLock { $0 }
    }
}

/// Runs a user-approved set of removals through `Cleaner`, worktrees before branches, one at a time,
/// reporting progress and stopping between items when cancelled.
public struct BatchCleaner: Sendable {
    private let cleaner: Cleaner

    public init(cleaner: Cleaner) {
        self.cleaner = cleaner
    }

    public func run(
        items: [CleanupItem], batchID: UUID = UUID(), now: Date = Date(), control: BatchControl? = nil
    ) -> AsyncStream<BatchEvent> {
        AsyncStream { continuation in
            let task = Task {
                var worktrees: [(URL, URL, VerdictKind, String?)] = []
                var branches: [(URL, String, VerdictKind)] = []
                for item in items {
                    switch item {
                    case .worktree(let repo, let path, let approved, let branch):
                        worktrees.append((repo, path, approved, branch))
                    case .branch(let repo, let name, let approved):
                        branches.append((repo, name, approved))
                    }
                }
                let bundled = worktrees.filter { $0.3 != nil }.count
                continuation.yield(.started(batchID: batchID, total: worktrees.count + branches.count + bundled))

                var removed = 0, skipped = 0, failed = 0, index = 0
                var records: [UndoRecord] = []
                var cancelled = false

                func record(_ item: CleanupItem, _ outcome: CleanOutcome) {
                    switch outcome {
                    case .removed(let undo):
                        removed += 1
                        records.append(undo)
                    case .skipped: skipped += 1
                    case .failed: failed += 1
                    }
                    continuation.yield(.itemFinished(index: index, item: item, outcome: outcome))
                    index += 1
                }

                var followUps: [(URL, String, VerdictKind)] = []
                for (repo, path, approved, branch) in worktrees {
                    if Task.isCancelled || control?.isStopRequested == true { cancelled = true; break }
                    let outcome = await cleaner.removeWorktree(
                        repoRoot: repo, path: path, approved: approved, batchID: batchID, now: now)
                    record(.worktree(repoRoot: repo, path: path, approved: approved, deleteBranch: branch), outcome)
                    if case .removed = outcome, let branch {
                        followUps.append((repo, branch, approved))
                    }
                }
                if !cancelled {
                    for (repo, name, approved) in branches + followUps {
                        if Task.isCancelled || control?.isStopRequested == true { cancelled = true; break }
                        let outcome = await cleaner.deleteBranch(
                            repoRoot: repo, name: name, approved: approved, batchID: batchID, now: now)
                        record(.branch(repoRoot: repo, name: name, approved: approved), outcome)
                    }
                }
                continuation.yield(.finished(BatchSummary(
                    batchID: batchID, removed: removed, skipped: skipped, failed: failed,
                    records: records, wasCancelled: cancelled)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
