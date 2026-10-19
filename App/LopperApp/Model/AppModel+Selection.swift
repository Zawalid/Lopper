import Foundation
import Lopper

/// How the repository table is divided into sections, each with its own checkbox.
enum RepoGrouping: String, CaseIterable, Identifiable {
    case none = "None"
    case tool = "Tool"
    case age = "Age"
    case verdict = "Verdict"
    case kind = "Kind"

    var id: Self { self }

    struct Key: Equatable {
        let id: String
        let title: String
        /// Where this section sits among the others.
        let order: Int
    }

    func key(for row: CleanupRow, now: Date = Date()) -> Key? {
        switch self {
        case .none:
            return nil
        case .tool:
            let name = row.agentHint ?? "No agent tool"
            return Key(id: "group:tool:\(name)", title: name, order: row.agentHint == nil ? 1 : 0)
        case .age:
            let bucket = RowSelection.ageBucket(of: row, now: now)
            return Key(id: "group:age:\(bucket.rawValue)", title: bucket.groupTitle, order: bucket.rawValue)
        case .verdict:
            let order = [VerdictKind.safe: 0, .review: 1, .protected: 2][row.verdict] ?? 3
            return Key(id: "group:verdict:\(row.verdict.label)", title: row.verdict.label, order: order)
        case .kind:
            return Key(
                id: "group:kind:\(row.kind.label)", title: row.kind == .worktree ? "Worktrees" : "Branches",
                order: row.kind == .worktree ? 0 : 1)
        }
    }

    static let idPrefix = "group:"
}

extension SelectionAffinity.AgeBucket {
    var groupTitle: String {
        switch self {
        case .thisWeek: "This week"
        case .thisMonth: "This month"
        case .thisQuarter: "Last 3 months"
        case .older: "Older than 3 months"
        case .unknown: "No date"
        }
    }
}

extension AppModel {
    /// What the table reports after a click: pick up the rows, and turn a clicked section into its rows.
    /// `sections` maps a section id to the ids of its rows as shown.
    func updateSelection(fromTable table: Set<String>, sections: [String: [CleanupRow]] = [:]) {
        let previous = checked
        var next = table.filter { !$0.hasPrefix(RepoGrouping.idPrefix) }
        for id in table where id.hasPrefix(RepoGrouping.idPrefix) {
            // Choosing a section header chooses what is in it, never the header itself.
            for row in sections[id] ?? [] where row.isSelectable { next.insert(row.id) }
        }
        setSelection(next, previous: previous)
    }

    /// Replaces the selection and moves the inspector to the row that was just chosen.
    func setSelection(_ ids: Set<String>, previous: Set<String>? = nil) {
        let before = previous ?? checked
        let added = ids.subtracting(before)
        let focus: String?
        if added.count == 1 {
            focus = added.first
        } else if ids.count == 1 {
            focus = ids.first
        } else if let current = focusedRowID, ids.contains(current) {
            focus = current
        } else {
            focus = ids.sorted().first
        }
        checked = ids
        focusedRowID = focus
        if let focus { selectionAnchor = focus }
    }

    /// A click on a row's checkbox: toggles it, or with Shift, sets every row from the last one clicked to this one.
    func toggleChecked(_ row: CleanupRow, extendingRange: Bool, order: [CleanupRow]) {
        guard row.isSelectable else { return }
        var next = checked
        let turningOn = !checked.contains(row.id)
        if extendingRange, let anchor = selectionAnchor {
            let selectable = Set(order.filter(\.isSelectable).map(\.id))
            for id in RowSelection.range(from: anchor, to: row.id, in: order.map(\.id)) where selectable.contains(id) {
                if turningOn { next.insert(id) } else { next.remove(id) }
            }
        } else if turningOn {
            next.insert(row.id)
        } else {
            next.remove(row.id)
        }
        let previous = checked
        setSelection(next, previous: previous)
        selectionAnchor = row.id
    }

    /// The header checkbox: picks every row that is shown and can be cleaned, or drops them again.
    func setAllShown(_ on: Bool, rows: [CleanupRow]) {
        let ids = Set(rows.filter(\.isSelectable).map(\.id))
        setSelection(on ? checked.union(ids) : checked.subtracting(ids))
    }

    func applyPreset(_ preset: SelectionPreset, rows: [CleanupRow], now: Date = Date()) {
        setSelection(RowSelection.apply(preset, rows: rows, current: checked, now: now))
    }

    func select(sharing affinity: SelectionAffinity, among rows: [CleanupRow], now: Date = Date()) {
        setSelection(Set(RowSelection.rows(sharing: affinity, among: rows, now: now).map(\.id)))
    }

    /// Drops the selected worktrees that may hold work only in their folder, which git would not remove anyway.
    func leaveOutFolderOnlyWork() {
        setSelection(checked.subtracting(RowSelection.foldersWithOnlyWork(selection: checked, allRows: allRows)))
    }

    func selectionSummary(shown rows: [CleanupRow]) -> SelectionSummary {
        RowSelection.summary(selection: checked, allRows: allRows, shownIDs: Set(rows.map(\.id)))
    }
}

// MARK: Agents page: the same choosing, where a ticked row is one that "Reclaim finished" will remove

extension AppModel {
    /// The shown agent worktrees that Reclaim finished could remove, which are the only ones with a checkbox.
    func eligibleAgentRows(shown: [AgentRow]) -> [AgentRow] { shown.filter { $0.assessment.isReclaimable } }

    func isAgentIncluded(_ id: String) -> Bool { !agentExcluded.contains(id) }

    func headerStateForAgents(shown: [AgentRow]) -> RowSelection.HeaderState {
        let eligible = eligibleAgentRows(shown: shown).map(\.id)
        return RowSelection.headerState(selection: Set(eligible.filter(isAgentIncluded)), selectable: eligible)
    }

    /// Ticks or unticks every shown worktree that can be reclaimed.
    func setAllAgentsShown(_ on: Bool, shown: [AgentRow]) {
        for item in eligibleAgentRows(shown: shown) { setAgentIncluded(item.id, on) }
    }

    /// A click on an agent's checkbox. With Shift it sets every row from the last one clicked to this one.
    func toggleAgentIncluded(_ item: AgentRow, extendingRange: Bool, order: [AgentRow]) {
        guard item.assessment.isReclaimable else { return }
        let turningOn = !isAgentIncluded(item.id)
        if extendingRange, let anchor = agentSelectionAnchor {
            let eligible = Set(eligibleAgentRows(shown: order).map(\.id))
            for id in RowSelection.range(from: anchor, to: item.id, in: order.map(\.id)) where eligible.contains(id) {
                setAgentIncluded(id, turningOn)
            }
        } else {
            setAgentIncluded(item.id, turningOn)
        }
        agentSelectionAnchor = item.id
    }

    func applyAgentPreset(_ preset: SelectionPreset, shown: [AgentRow], now: Date = Date()) {
        if preset == .none {
            // None means none: also the worktrees a filter is hiding.
            for item in agentRows where item.assessment.isReclaimable { setAgentIncluded(item.id, false) }
            return
        }
        let eligible = eligibleAgentRows(shown: shown)
        let included = Set(eligible.map(\.id).filter(isAgentIncluded))
        let picked = RowSelection.apply(preset, rows: eligible.map(\.row), current: included, now: now)
        for item in eligible { setAgentIncluded(item.id, picked.contains(item.id)) }
    }

    /// Includes only the shown, reclaimable worktrees that share `affinity` with the clicked one.
    func includeAgents(sharing affinity: SelectionAffinity, shown: [AgentRow], now: Date = Date()) {
        let eligible = eligibleAgentRows(shown: shown)
        let matching = Set(RowSelection.rows(sharing: affinity, among: eligible.map(\.row), now: now).map(\.id))
        for item in eligible { setAgentIncluded(item.id, matching.contains(item.id)) }
    }
}

