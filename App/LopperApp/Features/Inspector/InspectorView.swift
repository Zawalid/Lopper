import SwiftUI
import Lopper

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.focusedRow != nil {
            ScrollView { InspectorContent() }
        } else {
            EmptyState(
                symbol: "sidebar.right", title: "Select an item",
                message: "Pick a branch or worktree to see why Lopper thinks it is safe, or not.")
        }
    }
}

/// The inspector body without its scroll view, so it can be rendered offscreen.
struct InspectorContent: View {
    @Environment(AppModel.self) private var model
    @AppStorage("editorBundleID") private var editorBundleID = EditorChoice.vscode.rawValue

    var body: some View {
        if let row = model.focusedRow {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header(row)
                why(row)
                details(row)
                if !row.extraFiles.isEmpty { untracked(row) }
                actions(row)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            EmptyState(
                symbol: "sidebar.right", title: "Select an item",
                message: "Pick a branch or worktree to see why Lopper thinks it is safe, or not.")
        }
    }

    private func header(_ row: CleanupRow) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(row.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            HStack {
                VerdictChip(kind: row.verdict)
                Text(row.kind.label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func why(_ row: CleanupRow) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Why").font(.headline)
            ForEach(Array(row.reasons.enumerated()), id: \.offset) { _, reason in
                Label(reason, systemImage: row.verdict == .safe ? "checkmark" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(row.verdict == .safe ? Color.primary : Color.secondary)
            }
        }
    }

    private func details(_ row: CleanupRow) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.md, verticalSpacing: Theme.Spacing.sm) {
            if !row.reasons.contains(row.evidence) {
                GridRow {
                    Text("Evidence").foregroundStyle(.secondary)
                    Text(row.evidence)
                }
            }
            if let date = row.lastCommit {
                GridRow {
                    Text("Last commit").foregroundStyle(.secondary)
                    Text(date, format: .relative(presentation: .named))
                }
            }
            if row.kind == .worktree {
                GridRow {
                    Text("Location").foregroundStyle(.secondary)
                    Text(row.location).textSelection(.enabled).lineLimit(3)
                }
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    if let size = row.size { Text(SizeFormat.string(size)).monospacedDigit() } else { ProgressView().controlSize(.small) }
                }
            }
            GridRow {
                Text("Repository").foregroundStyle(.secondary)
                Text(row.repoName)
            }
        }
        .font(.callout)
    }

    private func untracked(_ row: CleanupRow) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Files git does not track").font(.headline)
            Text("These exist only in this worktree. If they are safe to lose in this repository, mark them as throwaway.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(row.extraFiles, id: \.self) { file in
                HStack {
                    Text(file).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Throwaway") {
                        model.addThrowaway(name: (file as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/")), repoRoot: row.repoRoot)
                    }
                    .controlSize(.small)
                    .help("Always treat this name as disposable in \(row.repoName)")
                }
            }
        }
    }

    private func actions(_ row: CleanupRow) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let url = row.prURL {
                Button { OpenActions.open(url) } label: {
                    Label("Open pull request", systemImage: "arrow.up.right.square")
                }
            }
            if let path = row.path {
                Button { OpenActions.reveal(path) } label: { Label("Reveal in Finder", systemImage: "folder") }
                Button { OpenActions.openInTerminal(path) } label: { Label("Open in Terminal", systemImage: "terminal") }
                if OpenActions.installed(editorBundleID) {
                    Button { OpenActions.openInEditor(path, bundleID: editorBundleID) } label: {
                        Label("Open in editor", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                Button { OpenActions.copy(path.path) } label: { Label("Copy path", systemImage: "doc.on.doc") }
            } else {
                Button { OpenActions.copy(row.title) } label: { Label("Copy branch name", systemImage: "doc.on.doc") }
            }
        }
        .buttonStyle(.link)
    }
}
