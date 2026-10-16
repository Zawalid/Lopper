import SwiftUI
import Charts
import Lopper

/// What was removed, when, why it was safe, and how to bring it back. Same structure as Agents and Disk:
/// a filter bar, one table, and an inspector for the selected entry.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = HistoryFilter()
    @State private var selection: UUID?
    @State private var pendingRestore: RestoreRequest?

    enum RestoreRequest: Identifiable {
        case entry(HistoryEntry)
        case cleanup(HistoryBatch)

        var id: UUID {
            switch self {
            case .entry(let entry): entry.id
            case .cleanup(let batch): batch.id
            }
        }
    }

    var body: some View {
        @Bindable var model = model
        let now = Date()
        let all = HistoryBuilder.entries(from: model.history)
        let summary = HistoryBuilder.summary(of: all, retentionDays: model.settings.trashRetentionDays, now: now)
        let selected = all.first { $0.id == selection }

        HistoryContent(
            entries: all, filter: $filter, selection: $selection, now: now,
            retentionDays: model.settings.trashRetentionDays,
            onRestore: { pendingRestore = .entry($0) })
            .navigationTitle("History")
            .navigationSubtitle(all.isEmpty ? "" : HistoryBuilder.summaryLine(summary))
            .searchable(text: $filter.query, placement: .toolbar, prompt: "Search history")
            .inspector(isPresented: Binding(
                // With nothing in the log there is nothing to inspect, so the page is just its empty state.
                get: { model.showInspector && !all.isEmpty },
                set: { if !all.isEmpty { model.showInspector = $0 } }
            )) {
                HistoryInspector(
                    entry: selected,
                    cleanup: selected.flatMap { HistoryBuilder.cleanup(containing: $0, in: all) },
                    retentionDays: model.settings.trashRetentionDays, now: now,
                    onRestore: { pendingRestore = .entry($0) },
                    onRestoreCleanup: { pendingRestore = .cleanup($0) })
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
            .confirmationDialog(
                title, isPresented: Binding(
                    get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                presenting: pendingRestore
            ) { request in
                Button(buttonTitle(request)) { perform(request) }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text(message(request))
            }
    }

    private var title: String {
        switch pendingRestore {
        case .entry(let entry): "Restore \(entry.title)?"
        case .cleanup(let batch): "Restore \(Plural.count(batch.restorableCount, "item"))?"
        case nil: "Restore?"
        }
    }

    private func buttonTitle(_ request: RestoreRequest) -> String {
        switch request {
        case .entry: "Restore"
        case .cleanup(let batch): "Restore \(Plural.count(batch.restorableCount, "item"))"
        }
    }

    private func message(_ request: RestoreRequest) -> String {
        switch request {
        case .entry(let entry):
            switch entry.kind {
            case .worktree: return "The folder and its branch come back exactly as they were removed."
            case .branch: return "The branch comes back at the commit it was removed at."
            case .folder: return "The folder is moved back out of the Trash to where it was."
            }
        case .cleanup:
            return "Everything in this cleanup that is still restorable comes back exactly as it was removed."
        }
    }

    private func perform(_ request: RestoreRequest) {
        switch request {
        case .entry(let entry): model.restore(entry)
        case .cleanup(let batch): if let id = batch.batchID { model.restoreBatch(id) }
        }
    }
}

/// The page body without toolbar and inspector, so it can be rendered offscreen.
struct HistoryContent: View {
    let entries: [HistoryEntry]
    @Binding var filter: HistoryFilter
    @Binding var selection: UUID?
    let now: Date
    let retentionDays: Int
    let onRestore: (HistoryEntry) -> Void

    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\HistoryEntry.date, order: .reverse)]

    var body: some View {
        Group {
            if entries.isEmpty {
                EmptyState(
                    symbol: "clock.arrow.circlepath", title: "No removals yet",
                    message: "Everything Lopper removes shows up here, and can be restored for \(retentionDays) days.")
            } else {
                VStack(spacing: 0) {
                    FreedChart(weeks: HistoryBuilder.weeklyFreed(entries: entries, now: now))
                    HistoryFilterBar(
                        entries: entries, filter: $filter,
                        selected: entries.first { $0.id == selection }, onRestore: onRestore)
                    table
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rows: [HistoryEntry] {
        filter.apply(to: entries, now: now).sorted(using: sortOrder)
    }

    @ViewBuilder private var table: some View {
        let rows = self.rows
        if rows.isEmpty {
            EmptyState(
                symbol: "line.3.horizontal.decrease.circle", title: "Nothing matches",
                message: "No removal fits those filters.",
                actionTitle: "Clear filters", action: { filter = HistoryFilter() })
        } else {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Item", value: \.title) { entry in ItemCell(entry: entry) }
                    .width(min: 140, ideal: 240)
                TableColumn("Why it was safe") { entry in
                    Text(entry.reason ?? "-")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(entry.reason ?? "")
                }
                .width(min: 80, ideal: 260)
                TableColumn("Size", value: \.sizeSort) { entry in
                    Text(entry.bytes.map { SizeFormat.string($0) } ?? "-")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 52, ideal: 72)
                TableColumn("Removed", value: \.date) { entry in
                    Text(HistoryBuilder.removedLabel(for: entry.date, now: now))
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                .width(min: 84, ideal: 124)
                TableColumn("Status") { entry in
                    StatusCell(entry: entry, retentionDays: retentionDays, now: now)
                }
                .width(min: 104, ideal: 150)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let entry = entries.first(where: { $0.id == id }) {
                    if entry.canRestore {
                        Button("Restore") { onRestore(entry) }
                    }
                    if let cleanup = HistoryBuilder.cleanup(containing: entry, in: entries),
                       cleanup.canRestoreAll, let batchID = cleanup.batchID {
                        Button("Restore the whole cleanup (\(cleanup.restorableCount))") {
                            model.restoreBatch(batchID)
                        }
                    }
                    Divider()
                    Button("Copy name") { model.copy(entry.title, confirming: "Copied name") }
                }
            } primaryAction: { ids in
                if let id = ids.first, let entry = entries.first(where: { $0.id == id }), entry.canRestore {
                    onRestore(entry)
                }
            }
        }
    }
}

/// Space given back per week: the page's proof that cleaning up is working.
private struct FreedChart: View {
    let weeks: [HistoryWeek]

    var body: some View {
        if weeks.contains(where: { $0.bytes > 0 }) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Space given back per week")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Chart(weeks) { week in
                    BarMark(
                        x: .value("Week", week.start, unit: .weekOfYear),
                        y: .value("Freed", week.bytes))
                        .foregroundStyle(Color.green.gradient)
                        .cornerRadius(3)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        if let bytes = value.as(Int64.self) {
                            AxisValueLabel(SizeFormat.string(bytes))
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .frame(height: 84)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.md)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Space given back per week, last \(weeks.count) weeks")
        }
    }
}

private struct HistoryFilterBar: View {
    let entries: [HistoryEntry]
    @Binding var filter: HistoryFilter
    let selected: HistoryEntry?
    let onRestore: (HistoryEntry) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Picker("Repository", selection: $filter.repoPath) {
                Text("All repositories").tag(String?.none)
                Divider()
                ForEach(HistoryBuilder.repositories(in: entries), id: \.path) { repo in
                    Text(repo.name).tag(String?.some(repo.path))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 170)

            Picker("When", selection: $filter.range) {
                ForEach(HistoryFilter.Range.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 170)

            Picker("Status", selection: $filter.status) {
                Text("Any status").tag(HistoryEntry.Status?.none)
                Divider()
                Text("Removed").tag(HistoryEntry.Status?.some(.removed))
                Text("Restored").tag(HistoryEntry.Status?.some(.restored))
                Text("Expired").tag(HistoryEntry.Status?.some(.expired))
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 170)

            if !filter.isEmpty {
                Button("Clear filters") { filter = HistoryFilter() }
                    .buttonStyle(.lopperLink)
            }

            Spacer(minLength: 0)

            Button("Restore") {
                if let selected { onRestore(selected) }
            }
            .buttonStyle(.lopperSecondary)
            .disabled(selected?.canRestore != true)
            .help("Bring the selected removal back")
        }
        .labelsHidden()
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: Cells

private struct ItemCell: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: HistoryStyle.symbol(for: entry.kind))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.data()).lineLimit(1).truncationMode(.middle)
                Text("\(entry.repoName) · \(entry.kindLabel)")
                    .font(.caption).foregroundStyle(Theme.metaText).lineLimit(1)
            }
        }
    }
}

private struct StatusCell: View {
    let entry: HistoryEntry
    let retentionDays: Int
    let now: Date

    var body: some View {
        switch entry.status {
        case .removed:
            Label(detail, systemImage: "arrow.uturn.backward.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.positiveText)
                .lineLimit(1)
                .help("Can be restored")
        case .restored:
            Label("Restored", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .expired:
            Label("Gone for good", systemImage: "clock.badge.xmark")
                .font(.caption).foregroundStyle(Theme.metaText)
        }
    }

    private var detail: String {
        if entry.kind == .folder { return "In the Trash" }
        let days = HistoryBuilder.daysLeft(for: entry, retentionDays: retentionDays, now: now)
        return days == 0 ? "Expires today" : "\(days)d left"
    }
}

enum HistoryStyle {
    static func symbol(for kind: HistoryEntry.Kind) -> String {
        switch kind {
        case .worktree: "rectangle.stack"
        case .branch: "arrow.triangle.branch"
        case .folder: "folder"
        }
    }
}

// MARK: Inspector

struct HistoryInspector: View {
    let entry: HistoryEntry?
    let cleanup: HistoryBatch?
    let retentionDays: Int
    let now: Date
    let onRestore: (HistoryEntry) -> Void
    let onRestoreCleanup: (HistoryBatch) -> Void

    var body: some View {
        if let entry {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    header(entry)
                    statusBanner(entry)
                    why(entry)
                    facts(entry)
                    if let cleanup { cleanupSection(cleanup) }
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar(entry) }
        } else {
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 28)).foregroundStyle(Theme.metaText)
                Text("Select a removal").font(.headline)
                Text("See what was removed, why it was safe, and bring it back.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(entry.title)
                .font(.data(.title3, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Spacing.sm) {
                Label(entry.kindLabel, systemImage: HistoryStyle.symbol(for: entry.kind))
                Text("·")
                Text(entry.repoName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statusBanner(_ entry: HistoryEntry) -> some View {
        switch entry.status {
        case .removed:
            if entry.kind == .folder {
                Banner(symbol: "trash", message: "In the Trash. Restoring moves it back where it was.")
            } else {
                let expiry = entry.date.addingTimeInterval(Double(retentionDays) * 86_400)
                Banner(
                    symbol: "arrow.uturn.backward.circle",
                    message: "Can be restored until \(expiry.formatted(date: .abbreviated, time: .omitted)).")
            }
        case .restored:
            Banner(symbol: "checkmark.circle", message: "This was restored. It is back where it was.")
        case .expired:
            Banner(
                symbol: "clock.badge.xmark",
                message: "The restore window has passed, so Lopper can no longer bring this back.")
        }
    }

    private func why(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Why it was safe").font(.headline)
            Text(entry.reason ?? "Lopper did not record a reason for this removal.")
                .font(.callout)
                .foregroundStyle(entry.reason == nil ? .tertiary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func facts(_ entry: HistoryEntry) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.md, verticalSpacing: Theme.Spacing.sm) {
            GridRow {
                Text("Removed").foregroundStyle(.secondary)
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
            }
            if let bytes = entry.bytes, bytes > 0 {
                GridRow {
                    Text("Freed").foregroundStyle(.secondary)
                    Text(SizeFormat.string(bytes))
                }
            }
            if entry.keptBranch {
                GridRow {
                    Text("Branch").foregroundStyle(.secondary)
                    Text("Kept. Only the folder was removed.")
                }
            }
            GridRow {
                Text("Repository").foregroundStyle(.secondary)
                Text(entry.repoPath)
                    .font(.callout.monospaced())
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .font(.callout)
    }

    private func cleanupSection(_ cleanup: HistoryBatch) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Same cleanup").font(.headline)
            Text("Removed together with \(Plural.count(cleanup.entries.count - 1, "other item")), "
                + "\(cleanup.date.formatted(date: .omitted, time: .shortened)).")
                .font(.callout).foregroundStyle(.secondary)
            if cleanup.canRestoreAll {
                Button("Restore all \(cleanup.restorableCount)") { onRestoreCleanup(cleanup) }
                    .buttonStyle(.lopperSecondary)
            }
        }
    }

    private func actionBar(_ entry: HistoryEntry) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            Button { onRestore(entry) } label: {
                Text(entry.canRestore ? "Restore" : "Cannot be restored").frame(maxWidth: .infinity)
            }
            .buttonStyle(.lopperPrimary)
            .controlSize(.large)
            .disabled(!entry.canRestore)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
