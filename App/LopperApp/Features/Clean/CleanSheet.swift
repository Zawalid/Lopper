import SwiftUI
import Lopper

struct CleanSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let state = model.clean {
            VStack(spacing: 0) {
                header(state)
                Divider()
                content(state)
                    // The middle always takes the room that is left, so the header stays at the top and the
                    // footer at the bottom even when the finished state has little to show.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer(state)
            }
            .frame(width: 560, height: 520)
            .interactiveDismissDisabled(model.isCleaning)
        }
    }

    private func header(_ state: CleanState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title(state)).font(.title3.weight(.semibold))
            Text(subtitle(state)).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.lg)
    }

    private func title(_ state: CleanState) -> String {
        switch state.phase {
        case .review: "Review and clean"
        case .running: "Cleaning…"
        case .finished: state.removedCount > 0 ? "Done" : "Nothing was removed"
        }
    }

    private func subtitle(_ state: CleanState) -> String {
        switch state.phase {
        case .review:
            let included = state.includedRows
            let size = state.includedBytes > 0 ? ", \(SizeFormat.string(state.includedBytes)) to reclaim" : ""
            return "\(Plural.count(included.count, "item"))\(size). Everything can be undone for \(model.settings.trashRetentionDays) days."
        case .running(let done, let total):
            return state.isStopping ? "Stopping after the current item…" : "\(done) of \(total)"
        case .finished:
            let size = state.reclaimedBytes > 0 ? ", \(SizeFormat.string(state.reclaimedBytes)) reclaimed" : ""
            return "Removed \(Plural.count(state.removedCount, "item"))\(size)."
        }
    }

    @ViewBuilder
    private func content(_ state: CleanState) -> some View {
        switch state.phase {
        case .review:
            VStack(spacing: 0) {
                let reviewCount = state.includedRows.filter { $0.verdict == .review }.count
                if reviewCount > 0 {
                    Banner(
                        symbol: "exclamationmark.triangle",
                        message: "\(Plural.count(reviewCount, "item")) could not be confirmed as merged. Their commits stay restorable from History.")
                        .padding(Theme.Spacing.md)
                }
                reviewList(state)
            }
        case .running(let done, let total):
            VStack(spacing: Theme.Spacing.md) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(maxWidth: 320)
                Text(state.outcomes.last.map { last in
                    switch last.status {
                    case .removed: "Removed \(last.title)"
                    case .skipped: "Left \(last.title) alone"
                    case .failed: "Couldn't remove \(last.title)"
                    }
                } ?? "Starting…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .finished:
            finishedList(state)
        }
    }

    private func reviewList(_ state: CleanState) -> some View {
        List {
            ForEach(groups(state), id: \.name) { group in
                Section(group.name) {
                    ForEach(group.rows) { row in
                        ReviewRow(row: row, isIncluded: !state.excluded.contains(row.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func finishedList(_ state: CleanState) -> some View {
        if state.problemCount == 0 {
            EmptyState(
                symbol: "checkmark.circle", title: "All set",
                message: "You can undo this from the toast or from History.")
        } else {
            List {
                Section("Not removed") {
                    ForEach(state.outcomes.filter { $0.status != .removed }) { outcome in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(outcome.title)
                            Text(outcome.message ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func footer(_ state: CleanState) -> some View {
        HStack {
            switch state.phase {
            case .review:
                Button("Cancel", role: .cancel) { model.dismissClean() }
                    .buttonStyle(.lopperSecondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Remove \(Plural.count(state.includedRows.count, "item"))") { model.runClean() }
                    .buttonStyle(.lopperPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.includedRows.isEmpty)
            case .running:
                Spacer()
                Button(state.isStopping ? "Stopping…" : "Stop") { model.cancelClean() }
                    .buttonStyle(.lopperSecondary)
                    .disabled(state.isStopping)
            case .finished:
                Spacer()
                Button("Done") { model.finishClean() }
                    .buttonStyle(.lopperPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.lg)
    }

    private struct RepoGroup { let name: String; let rows: [CleanupRow] }

    private func groups(_ state: CleanState) -> [RepoGroup] {
        Dictionary(grouping: state.rows, by: \.repoName)
            .map { RepoGroup(name: $0.key, rows: $0.value) }
            .sorted { $0.name < $1.name }
    }
}

struct ReviewRow: View {
    let row: CleanupRow
    let isIncluded: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Toggle("", isOn: Binding(
                get: { isIncluded },
                set: { model.setExcluded(row.id, !$0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Include \(row.title)")
            Image(systemName: row.kind.symbol).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).lineLimit(1)
                // Two lines: for an agent worktree this is where the saved branch's name appears, and a note
                // cut off at "lopper/saved/detached..." hides exactly what the person needs to read.
                Text(row.agent?.rowNote ?? row.reasons.first ?? row.evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if row.verdict == .review { VerdictChip(kind: .review) }
            if let size = row.size {
                Text(SizeFormat.string(size)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}
