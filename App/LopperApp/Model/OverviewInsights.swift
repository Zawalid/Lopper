import Foundation
import Lopper

/// One cleanup action as the Overview shows it: what was removed together, and whether it can still be undone.
struct ActivityBatch: Identifiable, Equatable {
    let id: UUID
    let batchID: UUID?
    let date: Date
    let itemCount: Int
    let repoNames: [String]
    let canRestore: Bool
}

/// The pure parts of the Overview: what to say and which history to show. Kept out of the view so every
/// wording rule and grouping rule is unit tested.
enum OverviewInsights {
    /// The last few cleanups, newest first. Records still being written and failed ones are not activity.
    static func recentActivity(history: [UndoRecord], limit: Int = 3) -> [ActivityBatch] {
        let shown = history.filter { $0.status != .pending && $0.status != .failed }
        let batches = Dictionary(grouping: shown) { $0.batchID ?? $0.id }.map { key, records in
            ActivityBatch(
                id: key,
                batchID: records.first?.batchID,
                date: records.map(\.timestamp).max() ?? .distantPast,
                itemCount: records.count,
                repoNames: Array(Set(records.map { URL(fileURLWithPath: $0.repoPath).lastPathComponent })).sorted(),
                canRestore: records.first?.batchID != nil && records.contains { $0.status == .completed })
        }
        return Array(batches.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// Items Lopper has removed and that are still removed: restored ones came back, failed ones never left.
    static func lifetimeRemoved(history: [UndoRecord]) -> Int {
        history.filter { $0.status == .completed || $0.status == .expired }.count
    }

    /// "5 branches and 2 worktrees in 1 repository are safe to remove", naming only what there is.
    static func safeSummary(branches: Int, worktrees: Int, repositories: Int) -> String {
        var parts: [String] = []
        if branches > 0 { parts.append(Plural.count(branches, "branch", "branches")) }
        if worktrees > 0 { parts.append(Plural.count(worktrees, "worktree")) }
        guard !parts.isEmpty else { return "Nothing is safe to remove" }

        let place = repositories == 1
            ? "in 1 repository"
            : "across \(Plural.count(repositories, "repository", "repositories"))"
        let verb = branches + worktrees == 1 ? "is" : "are"
        return "\(parts.joined(separator: " and ")) \(place) \(verb) safe to remove"
    }

    static func freshness(of date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "Scanned just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Scanned " + formatter.localizedString(for: date, relativeTo: now)
    }
}
