import SwiftUI
import Lopper

struct AgentsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        AgentsContent()
            .navigationTitle("Agents")
            .navigationSubtitle(subtitle)
            .searchable(text: $model.agentSearchText, placement: .toolbar, prompt: "Search agent worktrees")
            .inspector(isPresented: $model.showInspector) {
                InspectorView()
                    .inspectorColumnWidth(min: 240, ideal: 270, max: 400)
            }
    }

    private var subtitle: String {
        let summary = model.agentsSummary
        guard summary.total > 0 else { return "" }
        return "\(summary.reclaimable) finished · \(summary.notMerged) not merged · \(summary.active) active"
    }
}

/// The page body without toolbar and inspector, so it can be rendered offscreen.
struct AgentsContent: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder: [KeyPathComparator<AgentRow>] = []

    var body: some View {
        Group {
            switch model.agentsPageState {
            case .needsFolders:
                EmptyState(
                    symbol: "folder.badge.plus", title: "Choose your project folders",
                    message: "Lopper finds agent worktrees inside the repositories in your folders.",
                    actionTitle: "Choose folders", action: { FolderPicker.choose { model.setRoots($0) } })
            case .scanning:
                VStack(spacing: Theme.Spacing.md) {
                    ProgressView().controlSize(.large)
                    Text("Looking for agent worktrees…").foregroundStyle(.secondary)
                }
            case .noAgents(let repositories):
                EmptyState(
                    symbol: "sparkles", title: "No agent worktrees found",
                    message: "Lopper looked in \(Plural.count(repositories, "repository", "repositories")). "
                        + "It recognises worktrees made by Claude Code, Cursor, Codex and Conductor.",
                    actionTitle: "Add folder", action: { FolderPicker.choose { model.addRoots($0) } })
            case .nothingToReclaim, .ready:
                VStack(spacing: 0) {
                    HeaderStrip()
                    AgentFilterBar()
                    table
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rows: [AgentRow] {
        let visible = model.visibleAgentRows
        return sortOrder.isEmpty ? visible : visible.sorted(using: sortOrder)
    }

    @ViewBuilder private var table: some View {
        @Bindable var model = model
        if rows.isEmpty {
            EmptyState(
                symbol: "line.3.horizontal.decrease.circle", title: "Nothing matches",
                message: "Try a different search or filter.")
        } else {
            Table(rows, selection: $model.focusedRowID, sortOrder: $sortOrder) {
                TableColumn("") { item in
                    AgentCheckCell(
                        item: item,
                        isIncluded: !model.agentExcluded.contains(item.id),
                        setIncluded: { model.setAgentIncluded(item.id, $0) })
                }
                .width(28)
                TableColumn("Worktree", value: \.title) { item in WorktreeCell(item: item) }
                    .width(min: 100)
                TableColumn("State", value: \.stateSort) { item in StateChip(state: item.assessment.state) }
                    .width(min: 90, ideal: 104)
                TableColumn("Only here") { item in OnlyHereCell(work: item.assessment.uniqueWork) }
                    .width(min: 84, ideal: 150)
                TableColumn("Activity", value: \.activitySort) { item in ActivityCell(item: item) }
                    .width(min: 56, ideal: 74)
                TableColumn("Age", value: \.ageSort) { item in
                    Text(item.assessment.createdAt.map { AgeFormat.short(from: $0) } ?? "-")
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 44, ideal: 52)
                TableColumn("Size", value: \.sizeSort) { item in AgentSizeCell(row: item.row) }
                    .width(min: 52, ideal: 68)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let item = model.agentRows.first(where: { $0.id == id }) {
                    RowMenu(row: item.row, terminalBundleID: model.preferences.terminalBundleID)
                    if item.assessment.canReview {
                        Divider()
                        Button("Review and remove…") { model.beginReview(row: item.row) }
                    }
                }
            }
        }
    }
}

private struct HeaderStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = model.agentsSummary
        let included = model.reclaimableAgentRows
        let bytes = included.reduce(Int64(0)) { $0 + ($1.row.size ?? 0) }
        VStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(included.isEmpty
                        ? "Nothing to reclaim yet"
                        : "\(Plural.count(included.count, "finished worktree")), \(SizeFormat.string(bytes))")
                        .font(.headline)
                    if summary.measuring > 0 {
                        Text("Measuring \(summary.measuring) more…")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Everything removed can be undone for \(model.settings.trashRetentionDays) days.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button("Reclaim \(included.count) finished") { model.beginReclaimFinishedAgents() }
                    .buttonStyle(.borderedProminent)
                    .disabled(included.isEmpty || model.clean != nil)
            }
            if summary.notMerged > 0 || summary.abandonedReclaimable > 0 {
                HStack(spacing: Theme.Spacing.lg) {
                    if summary.notMerged > 0 {
                        Label("\(summary.notMerged) not merged", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.orange)
                            .help("These hold work that is not in the default branch. They are never part of Reclaim finished.")
                    }
                    Spacer(minLength: 0)
                    if summary.abandonedReclaimable > 0 {
                        Button("Reclaim \(summary.abandonedReclaimable) abandoned, keep branches") {
                            model.beginReclaimAbandonedAgents()
                        }
                        .disabled(model.clean != nil)
                        .help("Removes the folders only. Each branch keeps its commits. You review the list first.")
                    }
                }
            }
            if model.failedRepositoryCount > 0 {
                Banner(
                    symbol: "exclamationmark.triangle",
                    message: "\(Plural.count(model.failedRepositoryCount, "repository", "repositories")) could not be read. "
                        + "Agent worktrees there are not shown.",
                    actionTitle: "Rescan", action: { model.startScan() })
            }
            if model.prDetectionNote {
                Banner(
                    symbol: "link",
                    message: "Squash-merged agent work shows as not merged until the GitHub CLI is connected.")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct AgentFilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: Theme.Spacing.md) {
            Picker("State", selection: $model.agentFilter) {
                ForEach(AgentStateFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 190)
            .help("Filter by state")

            Picker("Tool", selection: $model.agentToolFilter) {
                Text("All tools").tag(AgentTool?.none)
                ForEach(AgentTool.allCases, id: \.self) { Text($0.label).tag(AgentTool?.some($0)) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 170)
            .help("Filter by tool")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct StateChip: View {
    let state: AgentState

    private var tint: Color {
        switch state {
        case .finished: .green
        case .unmerged, .abandoned: .orange
        case .active, .protected: .secondary
        }
    }

    var body: some View {
        Label(state.label, systemImage: state.symbol)
            .font(.caption.weight(state == .unmerged ? .bold : .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("State: \(state.label)")
    }
}

private struct AgentCheckCell: View {
    let item: AgentRow
    let isIncluded: Bool
    let setIncluded: (Bool) -> Void

    var body: some View {
        if item.assessment.isReclaimable {
            Toggle("", isOn: Binding(get: { isIncluded }, set: setIncluded))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Include \(item.title)")
        } else {
            Image(systemName: "lock")
                .foregroundStyle(.tertiary)
                .help(item.assessment.sheetNote.isEmpty ? item.assessment.state.label : item.assessment.sheetNote)
                .accessibilityLabel("Not part of Reclaim finished")
        }
    }
}

private struct WorktreeCell: View {
    let item: AgentRow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title).lineLimit(1)
            Text("\(item.row.repoName) · \(item.assessment.detection.label)")
                .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
    }
}

private struct OnlyHereCell: View {
    let work: UniqueWork

    var body: some View {
        if work.existsOnlyInFolder {
            Label(work.summary, systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
                .lineLimit(2)
                .help("Only in this folder: it exists nowhere else.")
        } else {
            Text(work.summary)
                .foregroundStyle(work.isEmpty ? .tertiary : .secondary)
                .lineLimit(2)
        }
    }
}

private struct ActivityCell: View {
    let item: AgentRow

    var body: some View {
        if !item.assessment.isActivityMeasured {
            ProgressView().controlSize(.small)
        } else {
            Text(item.assessment.lastActivity.map { AgeFormat.short(from: $0) } ?? "-")
                .foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct AgentSizeCell: View {
    let row: CleanupRow

    var body: some View {
        if let size = row.size {
            Text(SizeFormat.string(size)).monospacedDigit().foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}
