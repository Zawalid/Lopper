import SwiftUI
import Lopper

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let row = model.focusedRow {
            ScrollView { InspectorContent() }
                .safeAreaInset(edge: .bottom, spacing: 0) { InspectorActionBar(row: row) }
        } else {
            RepositoryPanel()
        }
    }
}

/// The inspector body without its scroll view, so it can be rendered offscreen.
struct InspectorContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let row = model.focusedRow {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                header(row)
                banner(row)
                evidence(row)
                facts(row)
                if let agent = row.agent { agentSection(agent) }
                if !row.extraFiles.isEmpty { untracked(row) }
                openActions(row)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            RepositoryPanel()
        }
    }

    // MARK: Header and verdict

    private func header(_ row: CleanupRow) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                Text(row.title)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                FeedbackButton(
                    title: "Copy name", systemImage: "doc.on.doc", successTitle: "Copied", iconOnly: true
                ) { OpenActions.copy(row.title) }
                    .buttonStyle(.lopperIcon)
            }
            HStack(spacing: Theme.Spacing.sm) {
                Label(row.kind.label, systemImage: row.kind.symbol)
                Text("·")
                Text(row.repoName)
                if let agent = row.agentHint {
                    Text("·")
                    Label(agent, systemImage: "sparkles")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func banner(_ row: CleanupRow) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: row.verdict.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(row.verdict.tint)
            Text(InspectorInsights.banner(for: row))
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .background(row.verdict.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(row.verdict.tint.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }

    // MARK: Evidence

    private func evidence(_ row: CleanupRow) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("What Lopper checked").font(.headline)
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ForEach(InspectorInsights.checklist(for: row)) { check in
                    CheckRow(check: check)
                }
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Color(nsColor: .separatorColor)))
        }
    }

    // MARK: Facts

    private func facts(_ row: CleanupRow) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.md, verticalSpacing: Theme.Spacing.sm) {
            if let date = row.lastCommit {
                GridRow {
                    Text("Last commit").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(date, format: .dateTime.day().month(.abbreviated).year())
                        Text(date, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let tip = row.facts.tip {
                GridRow {
                    Text("Commit").foregroundStyle(.secondary)
                    Text(InspectorInsights.shortHash(tip))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
            if let divergence = InspectorInsights.divergence(row.facts) {
                GridRow {
                    Text("Compared").foregroundStyle(.secondary)
                    Text(divergence)
                }
            }
            if row.kind == .worktree {
                GridRow {
                    Text("Location").foregroundStyle(.secondary)
                    Text(row.location).textSelection(.enabled).lineLimit(3)
                }
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    if let size = row.size {
                        Text(SizeFormat.string(size)).monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .font(.callout)
    }

    // MARK: Agent

    /// What the Agents page knows about a worktree an AI tool made: who made it, whether it is in use, and
    /// what it holds that exists nowhere else. Same card as "What Lopper checked".
    private func agentSection(_ agent: AgentAssessment) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Agent worktree").font(.headline)
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.md, verticalSpacing: Theme.Spacing.sm) {
                    GridRow {
                        Text("Made by").foregroundStyle(.secondary)
                        Text(agent.detection.label)
                    }
                    GridRow {
                        Text("State").foregroundStyle(.secondary)
                        StateChip(state: agent.state)
                    }
                    GridRow {
                        Text("Only here").foregroundStyle(.secondary)
                        Text(agent.uniqueWork.summary)
                            .foregroundStyle(agent.uniqueWork.existsOnlyInFolder ? Color.orange : Color.primary)
                    }
                    if let created = agent.createdAt {
                        GridRow {
                            Text("Created").foregroundStyle(.secondary)
                            Text(created, format: .relative(presentation: .named))
                        }
                    }
                    if let activity = agent.lastActivity {
                        GridRow {
                            Text("Last activity").foregroundStyle(.secondary)
                            Text(activity, format: .relative(presentation: .named))
                        }
                    }
                }
                .font(.callout)
                if !agent.sheetNote.isEmpty {
                    Text(agent.sheetNote).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Color(nsColor: .separatorColor)))
        }
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
                    FeedbackButton(title: "Throwaway", systemImage: "trash.slash", successTitle: "Added") {
                        model.addThrowaway(
                            name: (file as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                            repoRoot: row.repoRoot)
                    }
                    .buttonStyle(.lopperSecondary)
                    .controlSize(.small)
                    .help("Always treat this name as disposable in \(row.repoName)")
                }
            }
        }
    }

    // MARK: Open actions

    private func openActions(_ row: CleanupRow) -> some View {
        FlowLayout(spacing: Theme.Spacing.sm) {
            if let url = row.prURL {
                action("Pull request", "arrow.up.right.square") { OpenActions.open(url) }
            }
            if let path = row.path {
                action("Reveal", "folder") { OpenActions.reveal(path) }
                action("Terminal", "terminal") {
                    OpenActions.openInTerminal(path, bundleID: model.preferences.terminalBundleID)
                }
                if OpenActions.installed(model.preferences.editorBundleID) {
                    action("Editor", "chevron.left.forwardslash.chevron.right") {
                        OpenActions.openInEditor(path, bundleID: model.preferences.editorBundleID)
                    }
                }
                FeedbackButton(title: "Copy path", systemImage: "doc.on.doc", successTitle: "Copied") {
                    OpenActions.copy(path.path)
                }
                .buttonStyle(.lopperSecondary)
                .controlSize(.small)
            }
        }
    }

    private func action(_ title: String, _ symbol: String, _ perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Label(title, systemImage: symbol) }
            .buttonStyle(.lopperSecondary)
            .controlSize(.small)
    }
}

private struct CheckRow: View {
    let check: EvidenceCheck

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.title).font(.callout)
                if let detail = check.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(stateWord): \(check.title)"))
    }

    private var symbol: String {
        switch check.state {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .neutral: "minus.circle"
        }
    }

    private var tint: Color {
        switch check.state {
        case .passed: .green
        case .failed: .red
        case .warning: .orange
        case .neutral: .secondary
        }
    }

    private var stateWord: String {
        switch check.state {
        case .passed: "Yes"
        case .failed: "No"
        case .warning: "Caution"
        case .neutral: "Not applicable"
        }
    }
}

/// The one thing to do with the selected item, always in view. It opens the same review sheet as everywhere
/// else, so removing from here is never quicker or looser than removing from the table.
private struct InspectorActionBar: View {
    let row: CleanupRow
    @Environment(AppModel.self) private var model

    /// Why an agent worktree cannot go to the review sheet from here (still in use, or work that exists only
    /// in its folder), so this button never opens a sheet the Agents page would not offer.
    private var heldBack: String? {
        guard let agent = row.agent, !(agent.isReclaimable || agent.canReview) else { return nil }
        if agent.state == .active { return "Still in use, or measuring. Lopper leaves it alone for now." }
        return agent.sheetNote.isEmpty ? "Lopper will not remove this from here." : agent.sheetNote
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if row.isSelectable {
                Button { model.beginClean(rows: [row]) } label: {
                    Text("Review and clean this item").frame(maxWidth: .infinity)
                }
                .buttonStyle(.lopperPrimary)
                .controlSize(.large)
                .disabled(model.isCleaning || model.isScanning || heldBack != nil)
                if let heldBack {
                    Label(heldBack, systemImage: "hand.raised")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Label("Protected items are never removed", systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// What the panel shows with nothing selected: the repository itself, so it is never an empty box.
private struct RepositoryPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if case .repo(let id) = model.route, let summary = model.summaries.first(where: { $0.id == id }),
           summary.failure == nil {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.name).font(.title3.weight(.semibold))
                        Text(RowMapper.abbreviated(summary.root))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    HealthBar(safe: summary.safe, review: summary.review, protected: summary.protected)

                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        line("Safe to remove", "\(summary.safe)", VerdictKind.safe.tint)
                        line("Need a look", "\(summary.review)", VerdictKind.review.tint)
                        line("Protected", "\(summary.protected)", VerdictKind.protected.tint)
                        if summary.reclaimableBytes > 0 {
                            line("Can be reclaimed", SizeFormat.string(summary.reclaimableBytes), .blue)
                        }
                        if let main = summary.defaultBranch {
                            line("Default branch", main, .secondary)
                        }
                    }

                    Text("Pick a branch or worktree to see why Lopper thinks it is safe, or not.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            EmptyState(
                symbol: "sidebar.right", title: "Select an item",
                message: "Pick a branch or worktree to see why Lopper thinks it is safe, or not.")
        }
    }

    private func line(_ title: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}
