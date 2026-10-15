import SwiftUI
import Lopper

/// Review before generated folders go to the Trash. Same shape as the cleanup sheet, with its own wording:
/// nothing here is lost, it is regenerated or taken back from the Trash.
struct DiskReviewSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let state = model.diskClear {
            VStack(spacing: 0) {
                header(state)
                Divider()
                content(state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer(state)
            }
            .frame(width: 560, height: 520)
            .interactiveDismissDisabled(isRunning(state))
        }
    }

    private func isRunning(_ state: DiskClearState) -> Bool {
        if case .running = state.phase { true } else { false }
    }

    private func header(_ state: DiskClearState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title(state)).font(.title3.weight(.semibold))
            Text(subtitle(state)).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.lg)
    }

    private func title(_ state: DiskClearState) -> String {
        switch state.phase {
        case .review: state.title
        case .running: "Working…"
        case .finished: state.removed > 0 ? "Done" : "Nothing was cleared"
        }
    }

    private func subtitle(_ state: DiskClearState) -> String {
        switch state.phase {
        case .review:
            let size = state.includedBytes > 0 ? ", \(SizeFormat.string(state.includedBytes)) to free" : ""
            return "\(Plural.count(state.included.count, "folder"))\(size). They go to the Trash and can be put back."
        case .running(let done, let total):
            return state.isStopping ? "Stopping after the current folder…" : "\(done) of \(total)"
        case .finished:
            let size = state.reclaimedBytes > 0
                ? ", \(SizeFormat.string(state.reclaimedBytes)). The space is free once the Trash is emptied" : ""
            return "Moved \(Plural.count(state.removed, "folder")) to the Trash\(size)."
        }
    }

    @ViewBuilder
    private func content(_ state: DiskClearState) -> some View {
        switch state.phase {
        case .review:
            VStack(spacing: 0) {
                if !state.reinstallTargets.isEmpty {
                    Toggle(isOn: Binding(
                        get: { state.reinstall }, set: { model.setDiskReinstall($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Reinstall afterwards")
                            Text("Runs \(commands(state)) again in \(Plural.count(state.reinstallTargets.count, "project")), "
                                + "from the lockfile.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(Theme.Spacing.md)
                    Divider()
                }
                reviewList(state)
            }
        case .running(let done, let total):
            VStack(spacing: Theme.Spacing.md) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(maxWidth: 320)
                Text(runningLine(state))
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .finished:
            finishedContent(state)
        }
    }

    private func commands(_ state: DiskClearState) -> String {
        var seen: [String] = []
        for target in state.reinstallTargets where !seen.contains(target.how) { seen.append(target.how) }
        return seen.joined(separator: ", ")
    }

    private func runningLine(_ state: DiskClearState) -> String {
        if let last = state.outcomes.last {
            switch last.status {
            case .removed: return "Moved \(last.title)"
            case .skipped: return "Left \(last.title) alone"
            case .failed: return "Couldn't move \(last.title)"
            }
        }
        return "Starting…"
    }

    private func reviewList(_ state: DiskClearState) -> some View {
        List {
            ForEach(groups(state), id: \.name) { group in
                Section(group.name) {
                    ForEach(group.items) { artifact in
                        ReviewFolderRow(artifact: artifact, isIncluded: !state.excluded.contains(artifact.id))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func finishedContent(_ state: DiskClearState) -> some View {
        if state.problemCount == 0 {
            EmptyState(
                symbol: "checkmark.circle", title: "All set",
                message: state.reinstalled > 0
                    ? "Reinstalled in \(Plural.count(state.reinstalled, "project")). Undo from the toast or History."
                    : "Undo from the toast or History, or use Put Back in the Trash.")
        } else {
            List {
                Section("Needs a look") {
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

    private func footer(_ state: DiskClearState) -> some View {
        HStack {
            switch state.phase {
            case .review:
                Button("Cancel", role: .cancel) { model.dismissDiskClear() }
                    .buttonStyle(.lopperSecondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Move \(Plural.count(state.included.count, "folder")) to Trash") { model.runDiskClear() }
                    .buttonStyle(.lopperPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.included.isEmpty)
            case .running:
                Spacer()
                Button(state.isStopping ? "Stopping…" : "Stop") { model.stopDiskClear() }
                    .buttonStyle(.lopperSecondary)
                    .disabled(state.isStopping)
            case .finished:
                Spacer()
                Button("Done") { model.finishDiskClear() }
                    .buttonStyle(.lopperPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.lg)
    }

    private struct Group { let name: String; let items: [DiskArtifact] }

    private func groups(_ state: DiskClearState) -> [Group] {
        Dictionary(grouping: state.artifacts) {
            $0.location == .developerCache ? "Developer caches" : $0.checkoutRoot.lastPathComponent
        }
            .map { Group(name: $0.key, items: $0.value.sorted { $0.bytes > $1.bytes }) }
            .sorted { $0.name < $1.name }
    }
}

private struct ReviewFolderRow: View {
    let artifact: DiskArtifact
    let isIncluded: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Toggle("", isOn: Binding(
                get: { isIncluded },
                set: { model.setDiskExcluded(artifact.id, !$0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Include \(artifact.name)")
            Image(systemName: "folder").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(relativePath).lineLimit(1).truncationMode(.middle)
                if case .offered(let how) = artifact.removal {
                    Text("Comes back with \(how)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(SizeFormat.string(artifact.bytes)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var relativePath: String {
        let base = artifact.checkoutRoot.standardizedFileURL.path
        let path = artifact.path.standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : artifact.name
    }
}
