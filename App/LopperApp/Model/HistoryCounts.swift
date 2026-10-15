import Foundation
import Lopper

/// Counting what a person removed, as they would count it. One worktree that carried its branch is two
/// undo records (the folder and the branch) but one thing, so "4 items removed" never appears after removing two.
enum HistoryCounts {
    static func items(in records: [UndoRecord]) -> Int {
        let worktreeKeys = Set(records.compactMap { record -> String? in
            record.action == .removeWorktree ? key(record) : nil
        })
        return records.filter { record in
            guard record.action == .deleteBranch, let key = key(record) else { return true }
            return !worktreeKeys.contains(key)
        }.count
    }

    /// Same batch, same repository, same branch name. Records without a batch are never paired.
    static func key(_ record: UndoRecord) -> String? {
        guard let batch = record.batchID, let branch = record.branch else { return nil }
        return "\(batch.uuidString)|\(record.repoPath)|\(branch)"
    }
}
