import Foundation
import Lopper

/// One cleanup action as the Overview shows it: what was removed together, and whether it can still be undone.
struct ActivityBatch: Identifiable, Equatable {
    let id: UUID
    let batchID: UUID?
    let date: Date
    let itemCount: Int
    /// Items in this batch that are still removed (restored ones are not).
    let removedCount: Int
    let repoNames: [String]
    let canRestore: Bool
}

/// One review item as the Overview's "Worth a look" list shows it.
struct ReviewHighlight: Identifiable, Equatable {
    let id: String
    let title: String
    let repoName: String
    let repoID: String
    let kind: CleanupRow.Kind
    let evidence: String
    let lastCommit: Date?
}

struct StaleInsight: Equatable {
    let count: Int
    let days: Int

    var sentence: String {
        let noun = Plural.count(count, "item")
        return "\(noun) \(count == 1 ? "hasn't" : "haven't") been touched in \(days)+ days"
    }
}

/// The pure parts of the Overview: what to say and which history to show. Kept out of the view so every
/// wording rule and grouping rule is unit tested.
enum OverviewInsights {
    /// The last few cleanups, newest first. Records still being written and failed ones are not activity.
    static func recentActivity(history: [UndoRecord], limit: Int = 3) -> [ActivityBatch] {
        let shown = history.filter { $0.status != .pending && $0.status != .failed }
        let grouped = Dictionary(grouping: shown) { $0.batchID ?? $0.id }
        var batches: [ActivityBatch] = []
        for (key, records) in grouped {
            let removed = records.filter { $0.status == .completed || $0.status == .expired }.count
            let names = Set(records.map { URL(fileURLWithPath: $0.repoPath).lastPathComponent })
            let batchID = records.first?.batchID
            let hasCompleted = records.contains { $0.status == .completed }
            batches.append(ActivityBatch(
                id: key,
                batchID: batchID,
                date: records.map(\.timestamp).max() ?? .distantPast,
                itemCount: records.count,
                removedCount: removed,
                repoNames: names.sorted(),
                canRestore: batchID != nil && hasCompleted))
        }
        return Array(batches.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// Review items worth a person's attention, oldest first: unmerged and untouched is the decision that
    /// keeps getting put off. Items with an unknown age go last.
    static func reviewHighlights(rows: [CleanupRow], limit: Int = 4) -> [ReviewHighlight] {
        let review = rows.filter { $0.verdict == .review }.sorted { lhs, rhs in
            switch (lhs.lastCommit, rhs.lastCommit) {
            case let (l?, r?) where l != r: return l < r
            case (nil, .some): return false
            case (.some, nil): return true
            default: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        }
        return review.prefix(limit).map {
            ReviewHighlight(
                id: $0.id, title: $0.title, repoName: $0.repoName, repoID: $0.repoRoot.path,
                kind: $0.kind, evidence: $0.evidence, lastCommit: $0.lastCommit)
        }
    }

    /// How many branches and worktrees nobody has committed to for `staleDays`. Protected ones are the
    /// repository's own business and are not counted; unknown ages are not guessed at.
    static func staleInsight(rows: [CleanupRow], staleDays: Int, now: Date = Date()) -> StaleInsight? {
        let cutoff = now.addingTimeInterval(-Double(staleDays) * 86_400)
        let count = rows.filter { row in
            guard row.verdict != .protected, let date = row.lastCommit else { return false }
            return date < cutoff
        }.count
        return count > 0 ? StaleInsight(count: count, days: staleDays) : nil
    }

    /// Placeholder cards while a scan is still running: what is left to read, capped so the page stays calm.
    static func skeletonCount(done: Int, total: Int, limit: Int = 6) -> Int {
        max(0, min(limit, total - done))
    }

    /// "Just removed 8 items" for a cleanup that happened a few minutes ago and is still in effect.
    static func justRemoved(history: [UndoRecord], now: Date = Date(), within window: TimeInterval = 600) -> String? {
        guard let latest = recentActivity(history: history, limit: 1).first,
              latest.canRestore, latest.removedCount > 0,
              now.timeIntervalSince(latest.date) <= window else { return nil }
        return "Just removed \(Plural.count(latest.removedCount, "item"))"
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
