import SwiftUI
import Lopper

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var tidyExpanded = false
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        let preferences = model.preferences
        let sections = SidebarLayout.sections(
            summaries: model.summaries, grouping: preferences.sidebarGrouping, folders: model.settings.roots,
            query: query, sort: preferences.sidebarSort, showsTidy: preferences.sidebarShowsTidy)
        let showsGroupHeaders = preferences.sidebarGrouping != .flat

        VStack(spacing: 0) {
            List(selection: Binding<Route?>(
                get: { model.route },
                set: { if let route = $0 { model.route = route } }
            )) {
                Section {
                    Label("Overview", systemImage: "square.grid.2x2").tag(Route.overview)
                    Label("History", systemImage: "clock.arrow.circlepath").tag(Route.history)
                }

                Section {
                    if SidebarLayout.showsSearch(repositoryCount: model.summaries.count) {
                        TextField("Filter repositories", text: $query)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .listRowSeparator(.hidden)
                            .accessibilityLabel("Filter repositories")
                    }

                    ForEach(sections) { section in
                        let expanded = isExpanded(section)
                        if showsGroupHeaders {
                            GroupHeader(title: section.title, count: section.repos.count, isExpanded: expanded) {
                                toggle(section)
                            }
                            .listRowSeparator(.hidden)
                        }
                        if expanded || !showsGroupHeaders {
                            ForEach(section.repos) { summary in
                                SidebarRepoRow(
                                    summary: summary,
                                    isTidy: section.isTidy,
                                    showsDetails: preferences.sidebarShowsDetails,
                                    includesFolder: preferences.sidebarGrouping != .folder)
                                    .tag(Route.repo(summary.id))
                                    .contextMenu { RepoContextMenu(summary: summary) }
                            }
                        }
                    }

                    if sections.isEmpty {
                        Text(query.isEmpty ? "Nothing to show" : "No repositories match")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    RepositoriesHeader()
                }
            }
            .listStyle(.sidebar)

            SidebarFooter()
        }
    }

    /// Searching opens everything so a match is never hidden inside a collapsed group.
    private func isExpanded(_ section: SidebarSection) -> Bool {
        if !query.isEmpty { return true }
        return section.isTidy ? tidyExpanded : !collapsedGroups.contains(section.id)
    }

    private func toggle(_ section: SidebarSection) {
        withAnimation(.easeOut(duration: 0.15)) {
            if section.isTidy {
                tidyExpanded.toggle()
            } else if collapsedGroups.contains(section.id) {
                collapsedGroups.remove(section.id)
            } else {
                collapsedGroups.insert(section.id)
            }
        }
    }
}

/// A whole row is the button, so the group opens wherever it is clicked.
private struct GroupHeader: View {
    let title: String
    let count: Int
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
            .hoverHighlight()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides these repositories")
    }
}

private struct RepositoriesHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Text("Repositories")
            Spacer(minLength: 0)
            SidebarOptionsMenu()
        }
    }
}

/// Group, sort and what to show, in one menu next to the section title.
private struct SidebarOptionsMenu: View {
    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    var body: some View {
        let preferences = model.preferences
        Menu {
            Menu("Group by") {
                Picker("Group by", selection: Binding(
                    get: { preferences.sidebarGrouping },
                    set: { preferences.setSidebarGrouping($0) }
                )) {
                    ForEach(SidebarGrouping.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Menu("Sort by") {
                Picker("Sort by", selection: Binding(
                    get: { preferences.sidebarSort },
                    set: { preferences.setSidebarSort($0) }
                )) {
                    ForEach(SidebarSort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Menu("Show") {
                Toggle("Details", isOn: Binding(
                    get: { preferences.sidebarShowsDetails },
                    set: { preferences.setSidebarShowsDetails($0) }))
                Toggle("Tidy repositories", isOn: Binding(
                    get: { preferences.sidebarShowsTidy },
                    set: { preferences.setSidebarShowsTidy($0) }))
            }
            Divider()
            Button("Reset to Defaults") { preferences.resetSidebarOptions() }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12))
                .frame(width: 24, height: 22)
                .hoverHighlight()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Group, sort and choose what to show")
        .accessibilityLabel("Sidebar options")
    }
}

/// One small capsule per kind of count, so safe and review read as the same sort of thing.
private struct CountBadge: View {
    let count: Int
    let kind: VerdictKind

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(kind.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(kind.tint.opacity(0.16), in: Capsule())
            .help("\(count) \(kind == .safe ? "safe to remove" : "to review")")
    }
}

private struct SidebarRepoRow: View {
    let summary: RepoSummary
    let isTidy: Bool
    let showsDetails: Bool
    let includesFolder: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: summary.failure == nil ? "shippingbox" : "exclamationmark.triangle")
                .foregroundStyle(summary.failure == nil ? Color.secondary : VerdictKind.review.tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(summary.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isTidy ? .secondary : .primary)
                if showsDetails {
                    Text(summary.detailLine(includingFolder: includesFolder))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: Theme.Spacing.xs)

            HStack(spacing: 4) {
                if summary.safe > 0 { CountBadge(count: summary.safe, kind: .safe) }
                if summary.review > 0 { CountBadge(count: summary.review, kind: .review) }
            }
        }
        .padding(.vertical, showsDetails ? 2 : 0)
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

// MARK: Footer

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ScanStatus()
            Divider()
            HStack(spacing: 2) {
                Button {
                    FolderPicker.choose { model.addRoots($0) }
                } label: {
                    Label("Add folder", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(SidebarButtonStyle())
                .help("Add a folder to scan (Command-O)")

                Button {
                    model.startScan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(SidebarButtonStyle())
                .disabled(model.isScanning || model.isCleaning)
                .help("Rescan (Command-R)")
                .accessibilityLabel("Rescan")

                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(SidebarButtonStyle())
                .help("Settings (Command-comma)")
                .accessibilityLabel("Settings")
            }
            .padding(Theme.Spacing.xs)
        }
    }
}

/// Scan progress as a caption and a thin bar. When idle, what could be reclaimed, which opens the Overview.
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
            Button {
                model.route = .overview
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "sparkles").foregroundStyle(VerdictKind.safe.tint)
                    Text("\(SizeFormat.string(model.totals.reclaimableBytes)) can be reclaimed")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .font(.caption)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 6)
                .hoverHighlight()
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Spacing.xs)
            .padding(.top, Theme.Spacing.xs)
            .help("Open the Overview")
        }
    }
}
