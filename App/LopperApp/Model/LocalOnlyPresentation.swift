import Foundation
import Lopper

/// Which kinds of item the page shows. The three tiles at the top of the page are these filters.
enum LocalOnlyFilter: String, CaseIterable, Identifiable {
    case all
    case notPushed
    case uncommitted
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "Everything"
        case .notPushed: "Not pushed"
        case .uncommitted: "Uncommitted"
        case .other: "Other"
        }
    }

    /// What the filter covers, said once for the tooltip.
    var explanation: String {
        switch self {
        case .all: "Everything that exists only on this Mac."
        case .notPushed: "Branches with commits that no remote has."
        case .uncommitted: "Worktrees with changes or files that were never committed."
        case .other: "Stashes, commits that no branch holds, and rebases or merges left half done."
        }
    }

    func includes(_ kind: LocalOnlyItem.Kind) -> Bool {
        switch self {
        case .all: true
        case .notPushed: kind == .unpushedCommits
        case .uncommitted: kind == .uncommittedChanges
        case .other: kind == .stash || kind == .detachedCommits || kind == .operationInProgress
        }
    }
}

enum LocalOnlySort: String, CaseIterable, Identifiable {
    case risk
    case oldest
    case newest

    var id: Self { self }

    var title: String {
        switch self {
        case .risk: "Most at risk"
        case .oldest: "Oldest first"
        case .newest: "Newest first"
        }
    }
}

struct LocalOnlyQuery: Equatable {
    var filter: LocalOnlyFilter = .all
    var sort: LocalOnlySort = .risk
    var search = ""

    var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isSearching: Bool { !trimmedSearch.isEmpty }
    var isNarrowed: Bool { filter != .all || isSearching }
}

/// How many items each filter would show, with the commit total for the unpushed ones.
struct LocalOnlyCounts: Equatable {
    var all = 0
    var notPushed = 0
    var uncommitted = 0
    var other = 0
    var unpushedCommits = 0

    func count(for filter: LocalOnlyFilter) -> Int {
        switch filter {
        case .all: all
        case .notPushed: notPushed
        case .uncommitted: uncommitted
        case .other: other
        }
    }
}

/// One repository's worth of items, already filtered and ordered.
struct LocalOnlySection: Identifiable, Equatable {
    var id: String { repoRoot.path }
    let repoRoot: URL
    let repoName: String
    /// What matters most first.
    let items: [LocalOnlyItem]
    /// Worktrees where the only thing at risk is untracked files. Real, but quieter than the rest.
    let untrackedOnly: [LocalOnlyItem]

    var total: Int { items.count + untrackedOnly.count }
    var all: [LocalOnlyItem] { items + untrackedOnly }
    var unpushedCommits: Int { items.filter { $0.kind == .unpushedCommits }.reduce(0) { $0 + $1.count } }

    /// One `git push` per unpushed branch, for pasting into a terminal. Lopper never runs them.
    var pushCommands: [String] { items.compactMap(\.pushCommand) }
}

/// The pure part of the page: filtering, ordering and grouping. No views, no git.
enum LocalOnlyPresenter {
    /// How many rows a repository shows before "Show N more".
    static let rowsBeforeShowMore = 5

    static func counts(of items: [LocalOnlyItem], search: String = "") -> LocalOnlyCounts {
        var counts = LocalOnlyCounts()
        for item in items where matches(item, search: search) {
            counts.all += 1
            switch item.kind {
            case .unpushedCommits:
                counts.notPushed += 1
                counts.unpushedCommits += item.count
            case .uncommittedChanges: counts.uncommitted += 1
            case .stash, .detachedCommits, .operationInProgress: counts.other += 1
            }
        }
        return counts
    }

    static func sections(of items: [LocalOnlyItem], query: LocalOnlyQuery) -> [LocalOnlySection] {
        let shown = items.filter { query.filter.includes($0.kind) && matches($0, search: query.trimmedSearch) }
        let sections = Dictionary(grouping: shown, by: \.repoRoot).map { root, group -> LocalOnlySection in
            let quiet = group.filter(isUntrackedOnly)
            let main = group.filter { !isUntrackedOnly($0) }
            return LocalOnlySection(
                repoRoot: root, repoName: group[0].repoName,
                items: main.sorted(by: comparator(query.sort)),
                untrackedOnly: quiet.sorted(by: comparator(query.sort == .risk ? .newest : query.sort)))
        }
        return sections.sorted { lhs, rhs in
            if lhs.unpushedCommits != rhs.unpushedCommits { return lhs.unpushedCommits > rhs.unpushedCommits }
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            return lhs.repoName.localizedStandardCompare(rhs.repoName) == .orderedAscending
        }
    }

    static func isUntrackedOnly(_ item: LocalOnlyItem) -> Bool {
        item.kind == .uncommittedChanges && !item.hasTrackedChanges
    }

    static func matches(_ item: LocalOnlyItem, search: String) -> Bool {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        return [item.title, item.repoName, item.detail, item.branch ?? ""].contains {
            $0.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Commits no branch holds come first (nothing at all points at them), then unpushed branches with the most
    /// commits, then changes to tracked files, then half-done operations, then stashes. Ties go to the work that
    /// has been exposed the longest.
    static func riskRank(_ item: LocalOnlyItem) -> Int {
        switch item.kind {
        case .detachedCommits: 0
        case .unpushedCommits: 1
        case .uncommittedChanges: 2
        case .operationInProgress: 3
        case .stash: 4
        }
    }

    private static func comparator(_ sort: LocalOnlySort) -> (LocalOnlyItem, LocalOnlyItem) -> Bool {
        { lhs, rhs in
            let left = lhs.lastTouched ?? .distantPast
            let right = rhs.lastTouched ?? .distantPast
            switch sort {
            case .risk:
                if riskRank(lhs) != riskRank(rhs) { return riskRank(lhs) < riskRank(rhs) }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                if left != right { return left < right }
            case .oldest:
                if left != right { return left < right }
            case .newest:
                if left != right { return left > right }
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    /// Plain text for the whole page, to paste into a note or an issue. Lists what exists only on this Mac.
    static func report(of sections: [LocalOnlySection], now: Date = Date()) -> String {
        var lines = ["Exists only on this Mac (checked by Lopper)"]
        for section in sections {
            lines.append("")
            lines.append("\(section.repoName) (\(section.repoRoot.path))")
            for item in section.all {
                let age = item.lastTouched.map { ", \(AgeFormat.long(from: $0, to: now))" } ?? ""
                lines.append("  \(LocalOnlyKindStyle.label(item.kind)): \(item.title) - \(item.detail)\(age)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
