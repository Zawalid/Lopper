import Foundation
import Lopper

/// One thing that was removed, as a person would name it. A worktree and the branch it carried are two undo
/// records but one entry, and restoring the entry brings back both.
struct HistoryEntry: Identifiable, Equatable {
    enum Kind { case branch, worktree, folder }
    enum Status { case removed, restored, expired }

    let id: UUID
    /// The records to restore, branch first so a worktree can be re-attached to it.
    let records: [UndoRecord]
    let batchID: UUID?
    let title: String
    let kind: Kind
    let repoName: String
    let repoPath: String
    let date: Date
    let status: Status
    let reason: String?
    let bytes: Int64?
    /// A worktree folder was removed but its branch was kept, so the work was never deleted.
    let keptBranch: Bool
    /// The whole folder, changes and all, went to the Trash instead of being deleted. Its size is not freed until the
    /// Trash is emptied.
    let keptInTrash: Bool

    var canRestore: Bool { status == .removed }

    var kindLabel: String {
        switch kind {
        case .branch: "Branch"
        case .worktree: "Worktree"
        case .folder: "Folder"
        }
    }

    /// Entries with no known size sort below every measured one.
    var sizeSort: Int64 { bytes ?? -1 }
}

/// Entries removed by one action.
struct HistoryBatch: Identifiable, Equatable {
    let id: UUID
    let batchID: UUID?
    let date: Date
    let entries: [HistoryEntry]

    var bytes: Int64 { entries.reduce(0) { $0 + ($1.bytes ?? 0) } }
    var restorableCount: Int { entries.filter(\.canRestore).count }
    var canRestoreAll: Bool { batchID != nil && restorableCount > 0 }
}

struct HistoryDay: Identifiable, Equatable {
    let id: Date
    let title: String
    let batches: [HistoryBatch]
}

struct HistoryRepo: Equatable, Hashable {
    let name: String
    let path: String
}

struct HistorySummary: Equatable {
    var removedLast30Days = 0
    var restoredLast30Days = 0
    var bytesLast30Days: Int64 = 0
    /// Still removed and still restorable.
    var restorable = 0
    /// When the soonest restorable item stops being restorable.
    var nextExpiry: Date?
}

/// Space given back in one calendar week.
struct HistoryWeek: Identifiable, Equatable {
    let start: Date
    let bytes: Int64
    let count: Int

    var id: Date { start }
}

struct HistoryFilter: Equatable {
    enum Range: CaseIterable, Identifiable {
        case all, day, week, month

        var id: Self { self }

        var days: Int? {
            switch self {
            case .all: nil
            case .day: 1
            case .week: 7
            case .month: 30
            }
        }

        var title: String {
            switch self {
            case .all: "All time"
            case .day: "Last 24 hours"
            case .week: "Last 7 days"
            case .month: "Last 30 days"
            }
        }
    }

    var query = ""
    var repoPath: String?
    var range: Range = .all
    var status: HistoryEntry.Status?

    var isEmpty: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty && repoPath == nil && range == .all && status == nil
    }

    func apply(to entries: [HistoryEntry], now: Date) -> [HistoryEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let cutoff = range.days.map { now.addingTimeInterval(-Double($0) * 86_400) }
        return entries.filter { entry in
            if let repoPath, entry.repoPath != repoPath { return false }
            if let status, entry.status != status { return false }
            if let cutoff, entry.date < cutoff { return false }
            guard !needle.isEmpty else { return true }
            return entry.title.lowercased().contains(needle)
                || entry.repoName.lowercased().contains(needle)
                || (entry.reason?.lowercased().contains(needle) ?? false)
        }
    }
}

/// Everything the History page shows, derived from the undo log. Pure, so the grouping and the numbers are
/// unit tested.
enum HistoryBuilder {
    static func entries(from records: [UndoRecord]) -> [HistoryEntry] {
        // Pending records are mid-removal and failed ones removed nothing: neither is history.
        let shown = records.filter { $0.status != .pending && $0.status != .failed }

        var branchesByKey: [String: UndoRecord] = [:]
        for record in shown where record.action == .deleteBranch {
            if let key = HistoryCounts.key(record) { branchesByKey[key] = record }
        }

        var paired = Set<UUID>()
        var result: [HistoryEntry] = []
        for record in shown where record.action == .removeWorktree {
            var branchRecord: UndoRecord?
            if let key = HistoryCounts.key(record), let match = branchesByKey[key] {
                branchRecord = match
                paired.insert(match.id)
            }
            result.append(entry(primary: record, branchRecord: branchRecord))
        }
        for record in shown where record.action == .deleteBranch && !paired.contains(record.id) {
            result.append(entry(primary: record, branchRecord: nil))
        }
        for record in shown where record.action == .trashFolder || record.action == .trashWorktree {
            result.append(entry(primary: record, branchRecord: nil))
        }
        return result.sorted { $0.date > $1.date }
    }

    private static func entry(primary: UndoRecord, branchRecord: UndoRecord?) -> HistoryEntry {
        let records = [branchRecord, primary].compactMap { $0 }
        let isWorktree = primary.action == .removeWorktree || primary.action == .trashWorktree
        let statuses = records.map(\.status)
        let status: HistoryEntry.Status
        if statuses.contains(.completed) {
            status = .removed
        } else if statuses.allSatisfy({ $0 == .restored }) {
            status = .restored
        } else {
            status = .expired
        }
        let folder = primary.worktreePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        return HistoryEntry(
            id: primary.id,
            records: records,
            batchID: primary.batchID,
            title: primary.branch ?? folder ?? "(unnamed)",
            kind: isWorktree ? .worktree : (primary.action == .trashFolder ? .folder : .branch),
            repoName: URL(fileURLWithPath: primary.repoPath).lastPathComponent,
            repoPath: primary.repoPath,
            date: records.map(\.timestamp).max() ?? primary.timestamp,
            status: status,
            reason: primary.reason ?? branchRecord?.reason,
            bytes: primary.bytes,
            keptBranch: isWorktree && primary.branch != nil && branchRecord == nil,
            keptInTrash: primary.action == .trashWorktree)
    }

    static func batches(from entries: [HistoryEntry]) -> [HistoryBatch] {
        Dictionary(grouping: entries) { $0.batchID ?? $0.id }
            .map { key, entries in
                let sorted = entries.sorted { $0.date > $1.date }
                return HistoryBatch(
                    id: key, batchID: sorted.first?.batchID,
                    date: sorted.map(\.date).max() ?? .distantPast, entries: sorted)
            }
            .sorted { $0.date > $1.date }
    }

    static func days(from batches: [HistoryBatch], now: Date, calendar: Calendar = .current) -> [HistoryDay] {
        Dictionary(grouping: batches) { calendar.startOfDay(for: $0.date) }
            .map { start, batches in
                HistoryDay(
                    id: start, title: dayTitle(for: start, now: now, calendar: calendar),
                    batches: batches.sorted { $0.date > $1.date })
            }
            .sorted { $0.id > $1.id }
    }

    static func dayTitle(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let style = Date.FormatStyle(timeZone: calendar.timeZone).weekday(.wide).day().month(.abbreviated)
        return date.formatted(style)
    }

    static func repositories(in entries: [HistoryEntry]) -> [HistoryRepo] {
        Set(entries.map { HistoryRepo(name: $0.repoName, path: $0.repoPath) })
            .sorted { ($0.name.lowercased(), $0.path) < ($1.name.lowercased(), $1.path) }
    }

    static func summary(of entries: [HistoryEntry], retentionDays: Int, now: Date) -> HistorySummary {
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        var summary = HistorySummary()
        for entry in entries {
            if entry.date >= cutoff {
                switch entry.status {
                case .removed, .expired:
                    summary.removedLast30Days += 1
                    summary.bytesLast30Days += entry.bytes ?? 0
                case .restored:
                    summary.restoredLast30Days += 1
                }
            }
            if entry.status == .removed {
                summary.restorable += 1
                let expiry = entry.date.addingTimeInterval(Double(retentionDays) * 86_400)
                if summary.nextExpiry.map({ expiry < $0 }) ?? true { summary.nextExpiry = expiry }
            }
        }
        return summary
    }

    /// The last `weeks` weeks, oldest first, with what was removed in each and not restored since. Quiet weeks
    /// are kept so the chart's axis is honest.
    static func weeklyFreed(
        entries: [HistoryEntry], now: Date, weeks: Int = 12, calendar: Calendar = .current
    ) -> [HistoryWeek] {
        guard weeks > 0, let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        let starts = (0..<weeks).reversed().compactMap {
            calendar.date(byAdding: .weekOfYear, value: -$0, to: thisWeek)
        }
        var bytes = [Date: Int64](), counts = [Date: Int]()
        for entry in entries where entry.status != .restored {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: entry.date)?.start,
                  starts.contains(start) else { continue }
            bytes[start, default: 0] += entry.bytes ?? 0
            counts[start, default: 0] += 1
        }
        return starts.map { HistoryWeek(start: $0, bytes: bytes[$0] ?? 0, count: counts[$0] ?? 0) }
    }

    /// "Today 20:00", "Yesterday 22:00", "10 Jan": when something was removed, in the width of a table column.
    static func removedLabel(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(Date.FormatStyle(timeZone: calendar.timeZone).hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday \(time)" }
        return date.formatted(Date.FormatStyle(timeZone: calendar.timeZone).day().month(.abbreviated))
    }

    /// The page's subtitle: the three numbers that used to be tiles, in one line.
    static func summaryLine(_ summary: HistorySummary) -> String {
        guard summary.removedLast30Days > 0 else { return "Nothing removed in the last 30 days" }
        var parts = ["\(summary.removedLast30Days) removed in 30 days"]
        if summary.bytesLast30Days > 0 { parts.append("\(SizeFormat.string(summary.bytesLast30Days)) freed") }
        parts.append("\(summary.restorable) can be restored")
        return parts.joined(separator: " · ")
    }

    /// The other things removed by the same action, so the inspector can offer to bring them all back.
    /// Nil for a removal that stood alone.
    static func cleanup(containing entry: HistoryEntry, in entries: [HistoryEntry]) -> HistoryBatch? {
        guard let batchID = entry.batchID else { return nil }
        let members = entries.filter { $0.batchID == batchID }
        guard members.count > 1 else { return nil }
        let sorted = members.sorted { $0.date > $1.date }
        return HistoryBatch(
            id: batchID, batchID: batchID, date: sorted.map(\.date).max() ?? entry.date, entries: sorted)
    }

    /// Whole days a removal can still be restored, never negative.
    static func daysLeft(for entry: HistoryEntry, retentionDays: Int, now: Date) -> Int {
        let expiry = entry.date.addingTimeInterval(Double(retentionDays) * 86_400)
        return max(0, Int((expiry.timeIntervalSince(now) / 86_400).rounded(.up)))
    }
}
