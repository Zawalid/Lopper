import SwiftUI
import Lopper

struct RepoWorkbenchView: View {
    let repoID: String
    @Environment(AppModel.self) private var model
    @State private var sortOrder: [KeyPathComparator<RepoTableItem>] = []
    @State private var collapsed: Set<String> = []

    var body: some View {
        @Bindable var model = model
        let visible = model.visibleRows(forRepo: repoID)
        let items = RepoTableItems.build(
            rows: visible, sortOrder: sortOrder, grouping: model.repoGrouping, collapsed: collapsed)
        let sections = RepoTableItems.sections(items)
        let order = RepoTableItems.shownRows(items)
        let summary = model.summaries.first { $0.id == repoID }

        Group {
            if let failure = summary?.failure {
                EmptyState(
                    symbol: "exclamationmark.triangle", title: "Couldn't read this repository",
                    message: failure, actionTitle: "Rescan", action: { model.startScan() })
            } else if summary == nil && model.isScanning {
                // The route was restored before this repository has been read; do not claim it is empty.
                VStack(spacing: Theme.Spacing.md) {
                    ProgressView().controlSize(.large)
                    Text("Reading this repository…").foregroundStyle(.secondary)
                }
            } else if visible.isEmpty {
                EmptyState(
                    symbol: "line.3.horizontal.decrease.circle", title: "Nothing matches",
                    message: model.searchText.isEmpty && model.verdictFilter == .all && model.kindFilter == .all
                        ? "This repository has no extra branches or worktrees."
                        : "Try a different search or filter.")
            } else {
                table(items: items, visible: visible, order: order, sections: sections)
            }
        }
        .navigationTitle(summary?.name ?? "Repository")
        .navigationSubtitle(subtitle(summary))
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search branches and worktrees")
        // Fill the column whatever is inside. Without this an empty state is only as tall as its text, and the
        // filter bar and selection bar attached below float to the middle of the window with it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Filters sit above the table rather than in the toolbar: the toolbar already carries the title,
        // search, rescan and inspector, and a segmented control there squeezed the title and subtitle.
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if model.isOffline {
                    OfflineBanner().padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
                }
                FilterBar(shown: visible)
            }
        }
        .safeAreaInset(edge: .bottom) { SelectionBar(repoID: repoID, shown: visible) }
        .inspector(isPresented: $model.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 240, ideal: 270, max: 400)
        }
    }

    private func table(
        items: [RepoTableItem], visible: [CleanupRow], order: [CleanupRow], sections: [String: [CleanupRow]]
    ) -> some View {
        Table(
            items,
            selection: Binding(
                get: { model.checked },
                set: { model.updateSelection(fromTable: $0, sections: sections) }),
            sortOrder: $sortOrder
        ) {
            // Table cells are created in their own hosting views, so they get everything they need
            // passed in explicitly instead of reading AppModel from the environment.
            TableColumn("") { item in
                switch item.content {
                case .row(let row):
                    RowCheckbox(
                        isOn: model.checked.contains(row.id), isEnabled: row.isSelectable, title: row.title,
                        disabledReason: row.reasons.first ?? "Protected",
                        toggle: { model.toggleChecked(row, extendingRange: $0, order: order) })
                case .section(let section):
                    TriStateCheckbox(
                        state: RowSelection.headerState(selection: model.checked, selectable: section.selectableIDs),
                        help: "Select everything in \(section.key.title)",
                        isEnabled: !section.selectableIDs.isEmpty,
                        action: {
                            let state = RowSelection.headerState(selection: model.checked, selectable: section.selectableIDs)
                            model.setAllShown(state != .all, rows: section.rows)
                        })
                }
            }
            .width(32)
            TableColumn("Name", value: \.titleSort) { item in
                switch item.content {
                case .row(let row): NameCell(row: row)
                case .section(let section):
                    SectionHeaderCell(section: section) {
                        if collapsed.contains(section.key.id) { collapsed.remove(section.key.id) } else { collapsed.insert(section.key.id) }
                    }
                }
            }
            .width(min: 120)
            TableColumn("Verdict", value: \.verdictSort) { item in
                if let row = item.row { VerdictChip(kind: row.verdict) }
            }
            .width(min: 96, ideal: 100)
            TableColumn("Evidence", value: \.evidenceSort) { item in
                if let row = item.row { Text(row.evidence).foregroundStyle(.secondary).lineLimit(1) }
            }
            .width(min: 72, ideal: 150)
            TableColumn("Last commit", value: \.lastCommitSort) { item in
                if let row = item.row {
                    Text(row.lastCommit.map { AgeFormat.short(from: $0) } ?? "-")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .width(min: 64, ideal: 78)
            TableColumn("Size", value: \.sizeSort) { item in
                switch item.content {
                case .row(let row): SizeCell(row: row)
                case .section(let section):
                    if section.bytes > 0 {
                        Text(SizeFormat.string(section.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 52, ideal: 64)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            rowMenu(ids: ids, visible: visible, sections: sections)
        }
        .onKeyPress(.space) {
            // Space does what the checkbox does for the row the inspector shows.
            guard let id = model.focusedRowID, let row = visible.first(where: { $0.id == id }) else { return .ignored }
            model.toggleChecked(row, extendingRange: false, order: order)
            return .handled
        }
        .onKeyPress(.escape) {
            guard !model.checked.isEmpty else { return .ignored }
            model.setSelection([])
            return .handled
        }
    }

    @ViewBuilder
    private func rowMenu(ids: Set<String>, visible: [CleanupRow], sections: [String: [CleanupRow]]) -> some View {
        if ids.count == 1, let id = ids.first, let rows = sections[id] {
            Button("Select all \(rows.filter(\.isSelectable).count) in this section") {
                model.setSelection(Set(rows.filter(\.isSelectable).map(\.id)))
            }
        } else if let id = ids.first, let row = visible.first(where: { $0.id == id }) {
            if ids.count == 1 {
                RowMenu(
                    row: row, terminalBundleID: model.preferences.terminalBundleID,
                    copy: { model.copy($0, confirming: $1) })
                Divider()
            }
            SelectLikeMenu(row: row, rows: visible)
        }
        if !model.checked.isEmpty {
            Button("Clear the selection") { model.setSelection([]) }
        }
    }

    private func subtitle(_ summary: RepoSummary?) -> String {
        guard let summary else { return "" }
        return "\(summary.safe) safe · \(summary.review) review · \(summary.protected) protected"
    }
}

/// "Select all like this": the things a row shares with others, each with how many it would pick.
struct SelectLikeMenu: View {
    let row: CleanupRow
    let rows: [CleanupRow]
    @Environment(AppModel.self) private var model

    var body: some View {
        let offers = RowSelection.affinities(of: row).map { affinity in
            (affinity, RowSelection.rows(sharing: affinity, among: rows).count)
        }
        ForEach(Array(offers.enumerated()), id: \.offset) { _, offer in
            if offer.1 > 0 {
                Button(offer.0.title(count: offer.1)) { model.select(sharing: offer.0, among: rows) }
            }
        }
    }
}

private struct SectionHeaderCell: View {
    let section: RepoTableItem.Section
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(section.isCollapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(section.key.title).font(.headline)
                Text("\(section.rows.count)").font(.callout).foregroundStyle(Theme.metaText).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(section.isCollapsed ? "Show the rows in \(section.key.title)" : "Hide the rows in \(section.key.title)")
    }
}

private struct FilterBar: View {
    let shown: [CleanupRow]
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let state = RowSelection.headerState(selection: model.checked, selectable: shown.filter(\.isSelectable).map(\.id))
        HStack(spacing: Theme.Spacing.sm) {
            // The checkbox above the checkbox column: everything shown, none, or some.
            TriStateCheckbox(
                state: state,
                help: state == .all ? "Clear every row shown" : "Select every row shown",
                isEnabled: shown.contains(where: \.isSelectable),
                action: { model.setAllShown(state != .all, rows: shown) })
            Picker("Verdict", selection: $model.verdictFilter) {
                ForEach(VerdictFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Not fixedSize(): a fixed-size segmented control reports a huge ideal width and makes the
            // split view overflow the window, clipping the sidebar and the inspector.
            .frame(maxWidth: 340)
            .help("Filter by verdict")

            Picker("Kind", selection: $model.kindFilter) {
                ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 160)
            .help("Filter by kind")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct NameCell: View {
    let row: CleanupRow

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: row.kind.symbol)
                .foregroundStyle(.secondary)
                .accessibilityLabel(row.kind.label)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.data()).lineLimit(1)
                if row.kind == .worktree {
                    Text(row.location)
                        .font(.caption)
                        .foregroundStyle(Theme.metaText)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            if let agent = row.agentHint {
                Label(agent, systemImage: "sparkles")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}

private struct SizeCell: View {
    let row: CleanupRow

    var body: some View {
        if row.kind == .branch {
            Text("-").foregroundStyle(Theme.metaText)
        } else if let size = row.size {
            Text(SizeFormat.string(size)).monospacedDigit().foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

struct RowMenu: View {
    let row: CleanupRow
    var terminalBundleID: String = TerminalChoice.terminal.rawValue
    /// Copies text and tells the person it happened; a menu item cannot show that itself.
    var copy: (String, String) -> Void = { string, _ in OpenActions.copy(string) }

    var body: some View {
        if let path = row.path {
            Button("Reveal in Finder") { OpenActions.reveal(path) }
            Button("Open in Terminal") { OpenActions.openInTerminal(path, bundleID: terminalBundleID) }
            Button("Copy path") { copy(path.path, "Copied path") }
        } else {
            Button("Copy branch name") { copy(row.title, "Copied branch name") }
        }
        if let url = row.prURL {
            Button("Open pull request") { OpenActions.open(url) }
        }
    }
}

private struct SelectionBar: View {
    let repoID: String
    let shown: [CleanupRow]
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let summary = model.selectionSummary(shown: shown)
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                SelectionSummaryText(summary: summary)
                if summary.folderOnlyWork > 0 { folderOnlyWarning(summary.folderOnlyWork) }
            }
            Spacer()
            Menu {
                ForEach(0..<3, id: \.self) { group in
                    if group > 0 { Divider() }
                    ForEach(SelectionPreset.allCases.filter { $0.group == group }) { preset in
                        Button(preset.title) { model.applyPreset(preset, rows: shown) }
                            .help(preset.help)
                    }
                }
            } label: {
                Text("Select")
            }
            .menuStyle(.button)
            .buttonStyle(.lopperSecondary)
            .controlSize(.small)
            .fixedSize()
            .help("Pick rows by a rule: everything shown, only Safe, older than 30 days, larger than 100 MB and more")
            Menu {
                Picker("Group by", selection: $model.repoGrouping) {
                    ForEach(RepoGrouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(model.repoGrouping == .none ? "Group" : "Group: \(model.repoGrouping.rawValue)")
            }
            .menuStyle(.button)
            .buttonStyle(.lopperSecondary)
            .controlSize(.small)
            .fixedSize()
            .help("Divide the list into sections by tool, age, verdict or kind. Each section has its own checkbox.")
            Button("Select all safe") { model.checkAllSafe(inRepo: repoID) }
                .buttonStyle(.lopperSecondary)
                .controlSize(.small)
                .help("Pick every row Lopper can prove is safe in this repository")
            Button("Review and clean") { model.beginCleanChecked() }
                .buttonStyle(.lopperPrimary)
                .disabled(summary.isEmpty)
                .help("See exactly what would be removed before anything is. Everything can be undone for 30 days.")
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// "3 selected · 180.2 MB · 2 Safe, 1 Review", plus what is not obvious: rows a filter hides and rows that cannot go.
extension SelectionBar {
    /// Worktrees with changes or untracked files hold work that may exist only in their folder, and git will not remove
    /// those: say so before the review sheet, with one click to leave them out.
    fileprivate func folderOnlyWarning(_ count: Int) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            Text("\(Plural.count(count, "worktree")) may have changes that exist only in their folder, so git will skip them")
                .lineLimit(1)
                .truncationMode(.tail)
            Button("Leave those out") { model.leaveOutFolderOnlyWork() }
                .buttonStyle(.lopperLink)
                .help("Take these off the selection. Nothing in them is touched.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct SelectionSummaryText: View {
    let summary: SelectionSummary

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityLabel(text)
    }

    private var text: String {
        guard !summary.isEmpty else {
            return summary.skipped > 0 ? "Nothing to clean selected (\(summary.skipped) protected)" : "Nothing selected"
        }
        var parts = ["\(summary.count) selected"]
        if summary.bytes > 0 { parts.append("\(SizeFormat.string(summary.bytes)) to reclaim") }
        var kinds: [String] = []
        if summary.safe > 0 { kinds.append("\(summary.safe) Safe") }
        if summary.review > 0 { kinds.append("\(summary.review) Review") }
        parts.append(kinds.joined(separator: ", "))
        var line = parts.joined(separator: " · ")
        if summary.hidden > 0 { line += " (\(summary.hidden) hidden by filters)" }
        if summary.skipped > 0 { line += ", \(summary.skipped) protected skipped" }
        return line
    }
}
