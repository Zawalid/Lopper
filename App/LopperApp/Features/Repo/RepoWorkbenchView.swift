import SwiftUI
import Lopper

struct RepoWorkbenchView: View {
    let repoID: String
    @Environment(AppModel.self) private var model
    @State private var sortOrder: [KeyPathComparator<CleanupRow>] = []

    var body: some View {
        @Bindable var model = model
        let rows = sortedRows
        let summary = model.summaries.first { $0.id == repoID }

        Group {
            if let failure = summary?.failure {
                EmptyState(
                    symbol: "exclamationmark.triangle", title: "Couldn't read this repository",
                    message: failure, actionTitle: "Rescan", action: { model.startScan() })
            } else if rows.isEmpty {
                EmptyState(
                    symbol: "line.3.horizontal.decrease.circle", title: "Nothing matches",
                    message: model.searchText.isEmpty && model.verdictFilter == .all && model.kindFilter == .all
                        ? "This repository has no extra branches or worktrees."
                        : "Try a different search or filter.")
            } else {
                Table(rows, selection: $model.focusedRowID, sortOrder: $sortOrder) {
                    TableColumn("") { row in CheckCell(row: row) }
                        .width(28)
                    TableColumn("Name", value: \.title) { row in NameCell(row: row) }
                    TableColumn("Verdict", value: \.verdict) { row in VerdictChip(kind: row.verdict) }
                        .width(min: 96, ideal: 108)
                    TableColumn("Evidence", value: \.evidence) { row in
                        Text(row.evidence).foregroundStyle(.secondary).lineLimit(1)
                    }
                    TableColumn("Last commit", value: \.lastCommitSort) { row in
                        Text(row.lastCommit.map { AgeFormat.short(from: $0) } ?? "-")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .width(min: 70, ideal: 84)
                    TableColumn("Size", value: \.sizeSort) { row in SizeCell(row: row) }
                        .width(min: 70, ideal: 84)
                }
                .contextMenu(forSelectionType: CleanupRow.ID.self) { ids in
                    if let id = ids.first, let row = model.allRows.first(where: { $0.id == id }) {
                        RowMenu(row: row)
                    }
                }
            }
        }
        .navigationTitle(summary?.name ?? "Repository")
        .navigationSubtitle(subtitle(summary))
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search branches and worktrees")
        .toolbar {
            ToolbarItem {
                Picker("Verdict", selection: $model.verdictFilter) {
                    ForEach(VerdictFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Filter by verdict")
            }
            ToolbarItem {
                Picker("Kind", selection: $model.kindFilter) {
                    ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Filter by kind")
            }
        }
        .safeAreaInset(edge: .bottom) { SelectionBar(repoID: repoID) }
        .inspector(isPresented: $model.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 400)
        }
    }

    private var sortedRows: [CleanupRow] {
        let rows = model.visibleRows(forRepo: repoID)
        return sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)
    }

    private func subtitle(_ summary: RepoSummary?) -> String {
        guard let summary else { return "" }
        return "\(summary.safe) safe, \(summary.review) to review, \(summary.protected) protected"
    }
}

private struct CheckCell: View {
    let row: CleanupRow
    @Environment(AppModel.self) private var model

    var body: some View {
        Toggle(isOn: Binding(
            get: { model.checked.contains(row.id) },
            set: { isOn in
                if isOn { model.checked.insert(row.id) } else { model.checked.remove(row.id) }
            }
        )) { EmptyView() }
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(!row.isSelectable)
        .help(row.isSelectable ? "Select for cleaning" : (row.reasons.first ?? "Protected"))
        .accessibilityLabel("Select \(row.title)")
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
                Text(row.title).lineLimit(1)
                if row.kind == .worktree {
                    Text(row.location)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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
            Text("-").foregroundStyle(.tertiary)
        } else if let size = row.size {
            Text(SizeFormat.string(size)).monospacedDigit().foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

struct RowMenu: View {
    let row: CleanupRow

    var body: some View {
        if let path = row.path {
            Button("Reveal in Finder") { OpenActions.reveal(path) }
            Button("Open in Terminal") { OpenActions.openInTerminal(path) }
            Button("Copy path") { OpenActions.copy(path.path) }
        } else {
            Button("Copy branch name") { OpenActions.copy(row.title) }
        }
        if let url = row.prURL {
            Button("Open pull request") { OpenActions.open(url) }
        }
    }
}

private struct SelectionBar: View {
    let repoID: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let checked = model.checkedRows
        let bytes = checked.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        HStack {
            Text(checked.isEmpty
                ? "Nothing selected"
                : "\(checked.count) selected" + (bytes > 0 ? ", \(SizeFormat.string(bytes)) to reclaim" : ""))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select all safe") { model.checkAllSafe(inRepo: repoID) }
            Button("Review and clean") { model.beginCleanChecked() }
                .buttonStyle(.borderedProminent)
                .disabled(checked.isEmpty)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
