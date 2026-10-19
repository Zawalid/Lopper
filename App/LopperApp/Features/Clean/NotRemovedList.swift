import SwiftUI
import Lopper

/// Everything the removal left alone, each with the reason in plain words, the files in the way, and what can be done
/// about it. Nothing here forces anything: the strongest option moves the folder to the Trash with every file in it.
struct NotRemovedList: View {
    let state: CleanState
    @Environment(AppModel.self) private var model

    private var items: [ItemOutcome] { state.outcomes.filter { $0.status != .removed } }

    var body: some View {
        List {
            Section {
                ForEach(items) { outcome in
                    NotRemovedRow(
                        outcome: outcome, row: state.row(forOutcome: outcome.id),
                        changes: state.row(forOutcome: outcome.id).flatMap { state.changes[$0.id] },
                        isWorking: state.working.contains(outcome.id))
                }
            } header: {
                HStack {
                    Text("Not removed")
                    Spacer()
                    if items.count > 1 {
                        Button("Retry all") { model.retryNotRemoved(items.map(\.id)) }
                            .buttonStyle(.lopperLink)
                            .disabled(!state.working.isEmpty)
                            .help("Try each of these again, for example after saving or moving the files in the way")
                    }
                }
            }
        }
    }
}

struct NotRemovedRow: View {
    let outcome: ItemOutcome
    let row: CleanupRow?
    let changes: WorktreeChanges?
    let isWorking: Bool
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    private let visibleFiles = 4

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(outcome.title).font(.data()).lineLimit(1).truncationMode(.middle)
                if isWorking { ProgressView().controlSize(.small) }
            }
            Text(outcome.refusal.sentence)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if outcome.refusal == .other, let message = outcome.message, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if outcome.refusal == .hasChanges { files }
            actions
        }
        .padding(.vertical, Theme.Spacing.xs)
        .task(id: outcome.id) {
            if outcome.refusal == .hasChanges { await model.loadChanges(forOutcome: outcome.id) }
        }
        .confirmationDialog(
            "Move \(outcome.title) to the Trash?", isPresented: $confirming, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { model.removeKeepingCopy(outcomeID: outcome.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmation)
        }
    }

    @ViewBuilder
    private var files: some View {
        if let changes, changes.total > 0 {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Plural.count(changes.total, "file")) only in this folder")
                    .font(.caption.weight(.semibold))
                ForEach(changes.files.prefix(visibleFiles)) { change in
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(change.kind.label).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                        Text(change.path).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.caption.monospaced())
                }
                if changes.total > visibleFiles {
                    Text("and \(changes.total - visibleFiles) more. Copy the file list to see them all.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if changes == nil {
            Text("Looking at the files…").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                if let path = row?.path {
                    Button("Show in Finder") { OpenActions.reveal(path) }
                        .help("Open the folder in Finder to look at the files, save them or move them out")
                    Button("Open in Terminal") {
                        OpenActions.openInTerminal(path, bundleID: model.preferences.terminalBundleID)
                    }
                    .help("Open a terminal in this folder, for example to commit or stash the changes")
                }
                if let changes, changes.total > 0 {
                    Button("Copy file list") { OpenActions.copy(fileList(changes)) }
                        .help("Copy the names of the files in the way, to paste into a note or a commit")
                }
                Button("Retry") { model.retryNotRemoved([outcome.id]) }
                    .help("Try the removal again, for example after saving or moving the files in the way")
            }
            .buttonStyle(.lopperSecondary)
            .controlSize(.small)
            .disabled(isWorking)
            if canKeepACopy {
                Button("Remove anyway, keep a copy…") { confirming = true }
                    .buttonStyle(.lopperLink)
                    .controlSize(.small)
                    .disabled(isWorking)
                    .help("Move the whole folder to the Trash, files included, and let go of it in git. The branch stays, and History can put it all back.")
            }
        }
    }

    private var canKeepACopy: Bool {
        outcome.refusal.allowsKeepingACopy && row?.keepCopyRefusal == nil
    }

    private var confirmation: String {
        let count = changes.map { $0.total > 0 ? "all \(Plural.count($0.total, "file")) that exist only here and " : "" } ?? ""
        return "The whole folder moves to the Trash, including \(count)everything else in it. "
            + "The branch stays. You can bring the folder back from History for as long as it is in the Trash."
    }

    private func fileList(_ changes: WorktreeChanges) -> String {
        var lines = changes.files.map { "\($0.kind.label): \($0.path)" }
        if changes.hiddenCount > 0 { lines.append("and \(changes.hiddenCount) more") }
        return lines.joined(separator: "\n")
    }
}
