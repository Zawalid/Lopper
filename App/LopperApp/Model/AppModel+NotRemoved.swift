import Foundation
import Lopper

/// What happens around a worktree that git will not remove because its folder holds changes: a warning before, a
/// plain explanation after, a retry, and the option to move the folder to the Trash with a copy of everything in it.
extension AppModel {
    // MARK: Before

    /// Reads the files in the way for each included worktree that may hold folder-only work, so the sheet can say
    /// which ones git will skip. Worktrees with nothing odd about them are not even looked at.
    func checkForBlockingChanges() async {
        guard let state = clean, state.phase == .review else { return }
        let candidates = state.includedRows.filter { $0.mayHoldFolderOnlyWork && state.changes[$0.id] == nil }
        for row in candidates {
            let found = await client.blockingChanges(of: row)
            guard clean?.phase == .review else { return }
            clean?.changes[row.id] = found
        }
    }

    /// Leaves out exactly the worktrees git would skip.
    func leaveOutBlocked() {
        guard var state = clean, state.phase == .review else { return }
        state.excluded.formUnion(state.blockedRows.map(\.id))
        clean = state
    }

    // MARK: After

    /// Reads the files in the way of the worktree an outcome is about, fresh, because they may have changed.
    func loadChanges(forOutcome id: String) async {
        guard let row = clean?.row(forOutcome: id) else { return }
        let found = await client.blockingChanges(of: row)
        clean?.changes[row.id] = found
    }

    /// Tries the removal again for these items, one batch, in place: the sheet stays open and each result replaces
    /// the line it belongs to. Removals that work are undoable from the toast like any other.
    func retryNotRemoved(_ ids: [String]) {
        guard var state = clean, state.phase == .finished else { return }
        let rows = ids.filter { !state.working.contains($0) }.compactMap { state.row(forOutcome: $0) }
        let items = rows.compactMap(\.cleanupItem)
        guard !items.isEmpty else { return }
        let rowsByItemID = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.cleanupItem.map { ($0.id, row) } })
        let strictIDs = Set(rows.filter { $0.agent != nil }.compactMap { $0.cleanupItem?.id })
        var sizeHints: [String: Int64] = [:]
        for row in rows { if let item = row.cleanupItem, let size = row.size { sizeHints[item.id] = size } }
        state.working.formUnion(items.map(\.id))
        clean = state
        let settings = self.settings
        let stream = client.clean(
            items, settings: settings, control: BatchControl(), strictItemIDs: strictIDs, sizeHints: sizeHints)
        Task {
            var reclaimed: Int64 = 0
            var removed = 0
            var batch: UUID?
            for await event in stream {
                guard var current = clean else { break }
                switch event {
                case .started(let batchID, _):
                    batch = batchID
                case .itemFinished(_, let item, let outcome):
                    let row = rowsByItemID[item.id]
                    let title = row?.title ?? item.id
                    let result = Self.itemOutcome(id: item.id, title: title, outcome)
                    if let index = current.outcomes.firstIndex(where: { $0.id == item.id }) {
                        current.outcomes[index] = result
                    } else {
                        current.outcomes.append(result)
                    }
                    current.working.remove(item.id)
                    if case .removed = outcome, let row {
                        current.removedRows += 1
                        current.reclaimedBytes += row.size ?? 0
                        reclaimed += row.size ?? 0
                        removed += 1
                    }
                case .finished:
                    break
                }
                clean = current
            }
            clean?.working.subtract(items.map(\.id))
            if removed > 0, let batch { toast = UndoToast(id: batch, removed: removed, reclaimed: reclaimed) }
            await reloadHistory()
        }
    }

    /// Moves the folder of a worktree that was not removed to the Trash, drops git's record of it, and keeps the
    /// branch. Only for a folder whose files were the problem, one item at a time, and never for a worktree an agent
    /// may still be using: the same guard the engine applies, checked here too so nothing is even attempted.
    func removeKeepingCopy(outcomeID: String) {
        guard var state = clean, state.phase == .finished, !state.working.contains(outcomeID),
            let row = state.row(forOutcome: outcomeID),
            let outcome = state.outcomes.first(where: { $0.id == outcomeID }),
            outcome.status != .removed, outcome.refusal.allowsKeepingACopy, row.keepCopyRefusal == nil
        else { return }
        state.working.insert(outcomeID)
        clean = state
        let settings = self.settings
        Task {
            let result = await client.removeKeepingCopy(row, settings: settings)
            guard var current = clean else { return }
            current.working.remove(outcomeID)
            let updated = Self.itemOutcome(id: outcomeID, title: row.title, result)
            if let index = current.outcomes.firstIndex(where: { $0.id == outcomeID }) { current.outcomes[index] = updated }
            switch result {
            case .removed(let undo):
                // Nothing is freed until the Trash is emptied, so no space is claimed here.
                current.removedRows += 1
                toast = UndoToast(id: undo.batchID ?? undo.id, removed: 1, reclaimed: 0)
            case .skipped(let reason): record(.cleanProblem, "\(row.title) not moved to the Trash: \(reason)")
            case .failed(let message): record(.cleanProblem, "\(row.title) not moved to the Trash: \(message)")
            }
            clean = current
            await reloadHistory()
        }
    }
}
