import SwiftUI
import Lopper

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var tidyExpanded = false
    @State private var collapsedFolders: Set<String> = []

    var body: some View {
        let grouping = model.preferences.sidebarGrouping
        let sections = SidebarLayout.sections(
            summaries: model.summaries, grouping: grouping, folders: model.settings.roots, query: query)

        VStack(spacing: 0) {
            List(selection: Binding<Route?>(
                get: { model.route },
                set: { if let route = $0 { model.route = route } }
            )) {
                Section {
                    Label("Overview", systemImage: "square.grid.2x2").tag(Route.overview)
                    Label("History", systemImage: "clock.arrow.circlepath").tag(Route.history)
                }

                if SidebarLayout.showsSearch(repositoryCount: model.summaries.count) {
                    TextField("Filter repositories", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .listRowSeparator(.hidden)
                        .accessibilityLabel("Filter repositories")
                }

                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    Section(isExpanded: expansion(for: section)) {
                        ForEach(section.repos) { summary in
                            SidebarRepoRow(summary: summary, isTidy: section.isTidy)
                                .tag(Route.repo(summary.id))
                                .contextMenu { RepoContextMenu(summary: summary) }
                        }
                    } header: {
                        SectionHeader(section: section, showsGroupingMenu: index == 0)
                    }
                }

                if sections.isEmpty && !query.isEmpty {
                    Text("No repositories match")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)

            ScanStatus()
            Divider()
            SidebarFooter()
        }
    }

    /// Searching opens everything so a match is never hidden inside a collapsed group.
    private func expansion(for section: SidebarSection) -> Binding<Bool> {
        Binding(
            get: {
                if !query.isEmpty { return true }
                return section.isTidy ? tidyExpanded : !collapsedFolders.contains(section.id)
            },
            set: { expanded in
                if section.isTidy {
                    tidyExpanded = expanded
                } else if expanded {
                    collapsedFolders.remove(section.id)
                } else {
                    collapsedFolders.insert(section.id)
                }
            })
    }
}

private struct SectionHeader: View {
    let section: SidebarSection
    let showsGroupingMenu: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(section.title)
            Text("\(section.repos.count)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if showsGroupingMenu {
                Menu {
                    Picker("Group by", selection: Binding(
                        get: { model.preferences.sidebarGrouping },
                        set: { model.preferences.setSidebarGrouping($0) }
                    )) {
                        ForEach(SidebarGrouping.allCases) { grouping in
                            Label(grouping.title, systemImage: grouping.symbol).tag(grouping)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Group repositories")
                .accessibilityLabel("Group repositories")
            }
        }
    }
}

private struct SidebarRepoRow: View {
    let summary: RepoSummary
    let isTidy: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Label {
                Text(summary.name).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: summary.failure == nil ? "shippingbox" : "exclamationmark.triangle")
            }
            .foregroundStyle(isTidy ? .secondary : .primary)

            Spacer(minLength: Theme.Spacing.xs)

            if summary.review > 0 {
                Circle()
                    .fill(VerdictKind.review.tint)
                    .frame(width: 6, height: 6)
                    .help("\(summary.review) to review")
            }
            if summary.safe > 0 {
                Text("\(summary.safe)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(VerdictKind.safe.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(VerdictKind.safe.tint.opacity(0.18), in: Capsule())
                    .help("\(summary.safe) safe to remove")
            }
        }
        .help(RowMapper.abbreviated(summary.root))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(summary.name). \(summary.countsDescription)"))
    }
}

private struct RepoContextMenu: View {
    let summary: RepoSummary
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Reveal in Finder") { OpenActions.reveal(summary.root) }
        Button("Open in Terminal") {
            OpenActions.openInTerminal(summary.root, bundleID: model.preferences.terminalBundleID)
        }
        Button("Open in Editor") {
            OpenActions.openInEditor(summary.root, bundleID: model.preferences.editorBundleID)
        }
        Divider()
        Button("Hide Repository") { model.hideRepository(summary.root) }
    }
}

/// Scan progress, or when idle what could be reclaimed. A caption and a thin bar rather than a toolbar item,
/// which macOS draws as its own glass bubble next to the title.
private struct ScanStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if case .scanning(let done, let total) = model.phase {
            VStack(alignment: .leading, spacing: 4) {
                Text(total > 0 ? "Scanning \(done) of \(total)" : "Looking for repositories…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .accessibilityElement(children: .combine)
        } else if model.totals.reclaimableBytes > 0 {
            Text("\(SizeFormat.string(model.totals.reclaimableBytes)) can be reclaimed")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
        }
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Button {
                FolderPicker.choose { model.addRoots($0) }
            } label: {
                Label("Add folder", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .help("Add a folder to scan (Command-O)")
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings (Command-comma)")
            .accessibilityLabel("Settings")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }
}
