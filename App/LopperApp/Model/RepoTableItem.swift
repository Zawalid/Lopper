import Foundation
import Lopper

/// One line of the repository table: a branch or worktree, or the header of a section when the table is grouped.
/// The table sorts and shows these, so every column a person can sort by has a key here.
struct RepoTableItem: Identifiable, Equatable {
    struct Section: Equatable {
        let key: RepoGrouping.Key
        let rows: [CleanupRow]
        let isCollapsed: Bool

        var bytes: Int64 { rows.reduce(0) { $0 + ($1.size ?? 0) } }
        var selectableIDs: [String] { rows.filter(\.isSelectable).map(\.id) }
    }

    enum Content: Equatable {
        case row(CleanupRow)
        case section(Section)
    }

    let content: Content

    var id: String {
        switch content {
        case .row(let row): row.id
        case .section(let section): section.key.id
        }
    }

    var row: CleanupRow? {
        if case .row(let row) = content { row } else { nil }
    }

    var section: Section? {
        if case .section(let section) = content { section } else { nil }
    }

    // Sort keys. A section is never sorted among rows, so its keys only need to exist.
    var titleSort: String { row?.title ?? section?.key.title ?? "" }
    var verdictSort: VerdictKind { row?.verdict ?? .protected }
    var evidenceSort: String { row?.evidence ?? "" }
    var lastCommitSort: Date { row?.lastCommitSort ?? .distantPast }
    var sizeSort: Int64 { row?.sizeSort ?? section.map(\.bytes) ?? -1 }
}

enum RepoTableItems {
    /// The lines to show, in order: the rows sorted as asked, split into sections when grouped. A collapsed section
    /// shows only its header, and its rows stay selected if they were.
    static func build(
        rows: [CleanupRow], sortOrder: [KeyPathComparator<RepoTableItem>], grouping: RepoGrouping,
        collapsed: Set<String> = [], now: Date = Date()
    ) -> [RepoTableItem] {
        var items = rows.map { RepoTableItem(content: .row($0)) }
        if !sortOrder.isEmpty { items = items.sorted(using: sortOrder) }
        guard grouping != .none else { return items }

        var order: [String: RepoGrouping.Key] = [:]
        var members: [String: [CleanupRow]] = [:]
        for item in items {
            guard let row = item.row, let key = grouping.key(for: row, now: now) else { continue }
            order[key.id] = key
            members[key.id, default: []].append(row)
        }
        let keys = order.values.sorted { $0.order != $1.order ? $0.order < $1.order : $0.title < $1.title }
        var result: [RepoTableItem] = []
        for key in keys {
            let rows = members[key.id] ?? []
            let isCollapsed = collapsed.contains(key.id)
            result.append(RepoTableItem(content: .section(.init(key: key, rows: rows, isCollapsed: isCollapsed))))
            if !isCollapsed { result += rows.map { RepoTableItem(content: .row($0)) } }
        }
        return result
    }

    /// The rows in the order they are shown, for ranges: section headers are not rows.
    static func shownRows(_ items: [RepoTableItem]) -> [CleanupRow] { items.compactMap(\.row) }

    /// A section id to its rows, so a click on a header can choose what is in it.
    static func sections(_ items: [RepoTableItem]) -> [String: [CleanupRow]] {
        Dictionary(uniqueKeysWithValues: items.compactMap { item in item.section.map { (item.id, $0.rows) } })
    }
}
