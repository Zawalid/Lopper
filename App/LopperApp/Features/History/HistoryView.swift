import SwiftUI
import Lopper

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = HistoryFilter()
    @State private var expandedBatches: Set<UUID> = []
    @State private var pendingRestore: RestoreRequest?

    /// Batches with more entries than this are collapsed until opened, so one big cleanup does not bury the rest.
    private static let collapseAbove = 5

    private enum RestoreRequest: Identifiable {
        case entry(HistoryEntry)
        case batch(HistoryBatch)

        var id: UUID {
            switch self {
            case .entry(let entry): entry.id
            case .batch(let batch): batch.id
            }
        }
    }

    var body: some View {
        let now = Date()
        let all = HistoryBuilder.entries(from: model.history)
        let shown = filter.apply(to: all, now: now)
        let days = HistoryBuilder.days(from: HistoryBuilder.batches(from: shown), now: now)
        let summary = HistoryBuilder.summary(
            of: all, retentionDays: model.settings.trashRetentionDays, now: now)

        Group {
            if all.isEmpty {
                EmptyState(
                    symbol: "clock.arrow.circlepath", title: "No removals yet",
                    message: "Everything Lopper removes shows up here, and can be restored for \(model.settings.trashRetentionDays) days.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        summaryRow(summary, now: now)
                        filterBar(all)
                        if days.isEmpty {
                            EmptyState(
                                symbol: "line.3.horizontal.decrease.circle", title: "Nothing matches",
                                message: "No removal fits those filters.",
                                actionTitle: "Clear filters", action: { filter = HistoryFilter() })
                                .frame(minHeight: 240)
                        } else {
                            ForEach(days) { day in daySection(day, now: now) }
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("History")
        .searchable(text: $filter.query, placement: .toolbar, prompt: "Search history")
        .confirmationDialog(
            restoreTitle, isPresented: Binding(
                get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            presenting: pendingRestore
        ) { request in
            Button(restoreButtonTitle(request)) { perform(request) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(restoreMessage(request))
        }
    }

    // MARK: Summary and filters

    private func summaryRow(_ summary: HistorySummary, now: Date) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            StatTile(
                title: "Removed in 30 days", value: "\(summary.removedLast30Days)",
                symbol: "trash", tint: .secondary)
            StatTile(
                title: "Freed in 30 days",
                value: summary.bytesLast30Days > 0 ? SizeFormat.string(summary.bytesLast30Days) : "-",
                symbol: "internaldrive", tint: .blue)
            // Same one-line caption as its neighbours; each row below says how long it can still be restored.
            StatTile(
                title: "Can be restored", value: "\(summary.restorable)",
                symbol: "arrow.uturn.backward.circle", tint: VerdictKind.safe.tint)
        }
    }

    private func filterBar(_ all: [HistoryEntry]) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Picker("Repository", selection: $filter.repoPath) {
                Text("All repositories").tag(String?.none)
                Divider()
                ForEach(HistoryBuilder.repositories(in: all), id: \.path) { repo in
                    Text(repo.name).tag(String?.some(repo.path))
                }
            }
            .fixedSize()

            Picker("When", selection: $filter.range) {
                ForEach(HistoryFilter.Range.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()

            Picker("Status", selection: $filter.status) {
                Text("Any status").tag(HistoryEntry.Status?.none)
                Divider()
                Text("Removed").tag(HistoryEntry.Status?.some(.removed))
                Text("Restored").tag(HistoryEntry.Status?.some(.restored))
                Text("Expired").tag(HistoryEntry.Status?.some(.expired))
            }
            .fixedSize()

            Spacer(minLength: 0)

            if !filter.isEmpty {
                Button("Clear filters") { filter = HistoryFilter() }
                    .buttonStyle(.lopperLink)
            }
        }
        .labelsHidden()
    }

    // MARK: Days and batches

    private func daySection(_ day: HistoryDay, now: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(day.title)
                .font(.headline)
            ForEach(day.batches) { batch in batchCard(batch, now: now) }
        }
    }

    private func batchCard(_ batch: HistoryBatch, now: Date) -> some View {
        let collapsible = batch.entries.count > Self.collapseAbove
        let expanded = !collapsible || expandedBatches.contains(batch.id)

        return VStack(spacing: 0) {
            batchHeader(batch, collapsible: collapsible, expanded: expanded)
            if expanded {
                ForEach(batch.entries) { entry in
                    Divider()
                    EntryRow(entry: entry, retentionDays: model.settings.trashRetentionDays, now: now) {
                        pendingRestore = .entry(entry)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Color(nsColor: .separatorColor)))
    }

    private func batchHeader(_ batch: HistoryBatch, collapsible: Bool, expanded: Bool) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            if collapsible {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Plural.count(batch.entries.count, "item")) removed")
                    .font(.callout.weight(.semibold))
                Text(batchSubtitle(batch))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.md)
            if batch.canRestoreAll && batch.entries.count > 1 {
                Button("Restore all") { pendingRestore = .batch(batch) }
                    .buttonStyle(.lopperSecondary)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .contentShape(Rectangle())
        .onTapGesture {
            guard collapsible else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                if expandedBatches.contains(batch.id) { expandedBatches.remove(batch.id) } else { expandedBatches.insert(batch.id) }
            }
        }
    }

    private func batchSubtitle(_ batch: HistoryBatch) -> String {
        var parts = [batch.date.formatted(date: .omitted, time: .shortened)]
        let repos = Set(batch.entries.map(\.repoName)).sorted()
        parts.append(repos.prefix(3).joined(separator: ", ") + (repos.count > 3 ? " and \(repos.count - 3) more" : ""))
        if batch.bytes > 0 { parts.append(SizeFormat.string(batch.bytes) + " freed") }
        return parts.joined(separator: " · ")
    }

    // MARK: Restore confirmation

    private var restoreTitle: String {
        switch pendingRestore {
        case .entry(let entry): "Restore \(entry.title)?"
        case .batch(let batch): "Restore \(Plural.count(batch.restorableCount, "item"))?"
        case nil: "Restore?"
        }
    }

    private func restoreButtonTitle(_ request: RestoreRequest) -> String {
        switch request {
        case .entry: "Restore"
        case .batch(let batch): "Restore \(Plural.count(batch.restorableCount, "item"))"
        }
    }

    private func restoreMessage(_ request: RestoreRequest) -> String {
        switch request {
        case .entry(let entry):
            switch entry.kind {
            case .worktree: return "The folder and its branch come back exactly as they were removed."
            case .branch: return "The branch comes back at the commit it was removed at."
            case .folder: return "The folder is moved back out of the Trash to where it was."
            }
        case .batch:
            return "Everything in this cleanup that is still restorable comes back exactly as it was removed."
        }
    }

    private func perform(_ request: RestoreRequest) {
        switch request {
        case .entry(let entry): model.restore(entry)
        case .batch(let batch): if let id = batch.batchID { model.restoreBatch(id) }
        }
    }
}

private struct EntryRow: View {
    let entry: HistoryEntry
    let retentionDays: Int
    let now: Date
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: Self.symbol(for: entry.kind))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: Theme.Spacing.md)

            if let bytes = entry.bytes, bytes > 0 {
                Text(SizeFormat.string(bytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            trailing
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .accessibilityElement(children: .combine)
    }

    private static func symbol(for kind: HistoryEntry.Kind) -> String {
        switch kind {
        case .worktree: "rectangle.stack"
        case .branch: "arrow.triangle.branch"
        case .folder: "folder"
        }
    }

    private var subtitle: String {
        var parts = [entry.repoName]
        if let reason = entry.reason { parts.append(reason) }
        if entry.keptBranch { parts.append("branch kept") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailing: some View {
        switch entry.status {
        case .removed:
            let days = HistoryBuilder.daysLeft(for: entry, retentionDays: retentionDays, now: now)
            VStack(alignment: .trailing, spacing: 2) {
                Button("Restore", action: onRestore)
                    .buttonStyle(.lopperSecondary)
                    .controlSize(.small)
                Text(entry.kind == .folder ? "In the Trash"
                    : days == 0 ? "Expires today" : "\(Plural.count(days, "day")) left")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        case .restored:
            Label("Restored", systemImage: "arrow.uturn.backward")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .expired:
            Label("No longer restorable", systemImage: "clock.badge.xmark")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
