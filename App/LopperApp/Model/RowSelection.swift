import Foundation
import Lopper

/// Ready-made ways to choose rows, offered from the Select menu. Each one looks only at the rows that are on screen
/// and only ever picks rows that can be cleaned: a protected row is never added by a preset.
enum SelectionPreset: String, CaseIterable, Identifiable {
    case allVisible
    case none
    case invert
    case onlySafe
    case onlyReview
    case olderThan30Days
    case olderThan90Days
    case largerThan100MB
    case mergedIntoDefault
    case noUncommittedFiles

    var id: Self { self }

    var title: String {
        switch self {
        case .allVisible: "All shown"
        case .none: "None"
        case .invert: "Invert"
        case .onlySafe: "Only Safe"
        case .onlyReview: "Only Review"
        case .olderThan30Days: "Older than 30 days"
        case .olderThan90Days: "Older than 90 days"
        case .largerThan100MB: "Larger than 100 MB"
        case .mergedIntoDefault: "Already merged into the default branch"
        case .noUncommittedFiles: "With no uncommitted files"
        }
    }

    /// The tooltip: what it picks, and what it leaves out.
    var help: String {
        switch self {
        case .allVisible: "Pick every row you can see that can be cleaned. Protected rows are skipped."
        case .none: "Clear the whole selection, including rows a filter is hiding."
        case .invert: "Pick what is not picked among the rows shown, and drop what is."
        case .onlySafe: "Only rows Lopper can prove are safe. Worktrees an agent may still use are left out."
        case .onlyReview: "Only rows that need your judgement."
        case .olderThan30Days: "Rows whose last commit is at least 30 days old."
        case .olderThan90Days: "Rows whose last commit is at least 90 days old."
        case .largerThan100MB: "Worktrees that take at least 100 MB."
        case .mergedIntoDefault: "Rows whose work is already in the default branch, shown by a merge Lopper could prove."
        case .noUncommittedFiles: "Rows with no changed or untracked files, so nothing is lost with the folder."
        }
    }

    /// Separates the menu into the basics, the verdict, and the facts about a row.
    var group: Int {
        switch self {
        case .allVisible, .none, .invert: 0
        case .onlySafe, .onlyReview: 1
        default: 2
        }
    }
}

/// One thing a row shares with others, for "select all like this" in the right-click menu.
enum SelectionAffinity: Equatable {
    case verdict(VerdictKind)
    case tool(String)
    case ageBucket(AgeBucket)
    case kind(CleanupRow.Kind)

    enum AgeBucket: Int, Equatable {
        case thisWeek, thisMonth, thisQuarter, older, unknown

        var title: String {
            switch self {
            case .thisWeek: "within the last week"
            case .thisMonth: "from the last month"
            case .thisQuarter: "from the last 3 months"
            case .older: "older than 3 months"
            case .unknown: "with no date"
            }
        }
    }

    func title(count: Int) -> String {
        switch self {
        case .verdict(let kind): "Select all \(count) \(kind.label)"
        case .tool(let name): "Select all \(count) from \(name)"
        case .ageBucket(let bucket): "Select all \(count) \(bucket.title)"
        case .kind(let kind): "Select all \(count) \(kind == .worktree ? "worktrees" : "branches")"
        }
    }
}

/// What the footer says about the selection.
struct SelectionSummary: Equatable {
    var count = 0
    var bytes: Int64 = 0
    var safe = 0
    var review = 0
    /// Selected rows that a filter or the search is hiding right now.
    var hidden = 0
    /// Selected rows that cannot be cleaned (protected). They stay selected so they can be looked at, and are never removed.
    var skipped = 0

    var isEmpty: Bool { count == 0 }
}

/// The pure part of selecting rows: ranges, the header checkbox, presets and the footer summary.
enum RowSelection {
    enum HeaderState: Equatable { case none, some, all }

    /// The ids from `anchor` to `target` in the order shown, both included, whichever comes first.
    /// An id that is not shown gives just `target`.
    static func range(from anchor: String, to target: String, in order: [String]) -> [String] {
        guard let first = order.firstIndex(of: anchor), let second = order.firstIndex(of: target) else { return [target] }
        return Array(order[min(first, second)...max(first, second)])
    }

    static func headerState(selection: Set<String>, selectable: [String]) -> HeaderState {
        guard !selectable.isEmpty else { return .none }
        let picked = selectable.filter(selection.contains).count
        if picked == 0 { return .none }
        return picked == selectable.count ? .all : .some
    }

    /// The new selection after choosing a preset among the rows that are shown.
    static func apply(
        _ preset: SelectionPreset, rows: [CleanupRow], current: Set<String>, now: Date = Date()
    ) -> Set<String> {
        let eligible = rows.filter(\.isSelectable)
        let day: TimeInterval = 86_400
        func olderThan(_ days: Double) -> (CleanupRow) -> Bool {
            { row in row.lastCommit.map { now.timeIntervalSince($0) >= days * day } ?? false }
        }
        switch preset {
        case .none: return []
        case .allVisible: return Set(eligible.map(\.id))
        case .invert:
            let shown = Set(eligible.map(\.id))
            return current.subtracting(shown).union(shown.subtracting(current))
        case .onlySafe: return Set(eligible.filter(\.isBulkEligible).map(\.id))
        case .onlyReview: return Set(eligible.filter { $0.verdict == .review }.map(\.id))
        case .olderThan30Days: return Set(eligible.filter(olderThan(30)).map(\.id))
        case .olderThan90Days: return Set(eligible.filter(olderThan(90)).map(\.id))
        case .largerThan100MB: return Set(eligible.filter { ($0.size ?? 0) >= 100 * 1_048_576 }.map(\.id))
        case .mergedIntoDefault: return Set(eligible.filter { $0.facts.evidence.isStrong }.map(\.id))
        case .noUncommittedFiles:
            return Set(eligible.filter { !$0.facts.isDirty && $0.extraFiles.isEmpty }.map(\.id))
        }
    }

    static func ageBucket(of row: CleanupRow, now: Date = Date()) -> SelectionAffinity.AgeBucket {
        guard let date = row.lastCommit else { return .unknown }
        let days = now.timeIntervalSince(date) / 86_400
        switch days {
        case ..<7: return .thisWeek
        case ..<30: return .thisMonth
        case ..<90: return .thisQuarter
        default: return .older
        }
    }

    /// What `row` shares with other rows, in the order the menu lists them.
    static func affinities(of row: CleanupRow, now: Date = Date()) -> [SelectionAffinity] {
        var result: [SelectionAffinity] = [.verdict(row.verdict)]
        if let tool = row.agentHint { result.append(.tool(tool)) }
        result.append(.ageBucket(ageBucket(of: row, now: now)))
        result.append(.kind(row.kind))
        return result
    }

    static func matches(_ row: CleanupRow, _ affinity: SelectionAffinity, now: Date = Date()) -> Bool {
        switch affinity {
        case .verdict(let kind): row.verdict == kind
        case .tool(let name): row.agentHint == name
        case .ageBucket(let bucket): ageBucket(of: row, now: now) == bucket
        case .kind(let kind): row.kind == kind
        }
    }

    /// The rows that share `affinity` among the rows shown, restricted to what can be cleaned.
    static func rows(sharing affinity: SelectionAffinity, among rows: [CleanupRow], now: Date = Date()) -> [CleanupRow] {
        rows.filter { $0.isSelectable && matches($0, affinity, now: now) }
    }

    static func summary(selection: Set<String>, allRows: [CleanupRow], shownIDs: Set<String>) -> SelectionSummary {
        var summary = SelectionSummary()
        for row in allRows where selection.contains(row.id) {
            guard row.isSelectable else {
                summary.skipped += 1
                continue
            }
            summary.count += 1
            summary.bytes += row.size ?? 0
            if row.verdict == .safe { summary.safe += 1 } else { summary.review += 1 }
            if !shownIDs.contains(row.id) { summary.hidden += 1 }
        }
        return summary
    }
}
