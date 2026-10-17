import SwiftUI
import Lopper

struct LocalOnlyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        LocalOnlyContent()
            .navigationTitle("Only on this Mac")
            .navigationSubtitle(model.localOnly.isEmpty ? "" : "\(model.localOnlySummary.items) not backed up")
    }
}

/// The page body without toolbar, so it can be rendered offscreen.
struct LocalOnlyContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.localOnlyPageState {
            case .needsFolders:
                EmptyState(
                    symbol: "folder.badge.plus", title: "Choose your project folders",
                    message: "Lopper looks for work that exists only on this Mac inside the repositories in your folders.",
                    actionTitle: "Choose folders", action: { FolderPicker.choose { model.setRoots($0) } })
            case .scanning:
                VStack(spacing: Theme.Spacing.md) {
                    ProgressView().controlSize(.large)
                    Text("Checking what is backed up…").foregroundStyle(.secondary)
                }
            case .allBackedUp(let repositories):
                EmptyState(
                    symbol: "checkmark.icloud", title: "Everything is backed up",
                    message: "Nothing in \(Plural.count(repositories, "repository", "repositories")) exists only on this Mac. "
                        + "Every branch is pushed or merged, and no stash or uncommitted change is waiting.")
            case .ready:
                ScrollView { LocalOnlyList() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The list inside the scroll view, separate so it can be rendered offscreen.
struct LocalOnlyList: View {
    @Environment(AppModel.self) private var model
    @State private var query = LocalOnlyQuery()
    /// Item ids whose rows start open. Only the offscreen renders and tests pass anything here.
    private let initiallyOpen: Set<String>

    init(initiallyOpen: Set<String> = []) {
        self.initiallyOpen = initiallyOpen
    }

    var body: some View {
        let sections = LocalOnlyPresenter.sections(of: model.localOnly, query: query)
        let counts = LocalOnlyPresenter.counts(of: model.localOnly, search: query.trimmedSearch)
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            header(sections: sections)
            FilterTiles(counts: counts, selection: $query.filter)
            controls
            if sections.isEmpty {
                NoMatches(query: query) { query = LocalOnlyQuery(sort: query.sort) }
            } else {
                VStack(spacing: Theme.Spacing.lg) {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        SectionCard(
                            section: section, startsExpanded: index == 0 || query.isNarrowed,
                            limitsRows: !query.isSearching, initiallyOpen: initiallyOpen)
                    }
                }
            }
        }
        .padding(32)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }

    private func header(sections: [LocalOnlySection]) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(LocalOnlyKindStyle.headline(model.localOnlySummary)).font(.title3.weight(.semibold))
                Text("If this Mac or one of these folders were lost, this work would be lost with it. "
                    + "Open a row to see what is in it. Lopper never removes anything here and never pushes for you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { model.copyLocalOnlyReport(sections) } label: {
                Label("Copy list", systemImage: "doc.on.doc")
            }
            .buttonStyle(.lopperSecondary)
            .controlSize(.small)
            .disabled(sections.isEmpty)
            .help("Copy everything shown below as plain text, to paste into a note or an issue.")
        }
    }

    private var controls: some View {
        HStack(spacing: Theme.Spacing.md) {
            SearchField(text: $query.search)
            Menu {
                Picker("Sort by", selection: $query.sort) {
                    ForEach(LocalOnlySort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort: \(query.sort.title)", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.button)
            .buttonStyle(.lopperSecondary)
            .controlSize(.small)
            .fixedSize()
            .help("Change the order of the rows inside each repository.")
        }
    }
}

// MARK: Filter tiles

private struct FilterTiles: View {
    let counts: LocalOnlyCounts
    @Binding var selection: LocalOnlyFilter

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            tile(.notPushed, symbol: "arrow.up.circle", note: counts.unpushedCommits == 0
                ? "" : Plural.count(counts.unpushedCommits, "commit"), tint: Theme.cautionText)
            tile(.uncommitted, symbol: "pencil.circle", note: "in worktrees", tint: .secondary)
            tile(.other, symbol: "tray", note: "stashes and loose commits", tint: .secondary)
        }
    }

    private func tile(_ filter: LocalOnlyFilter, symbol: String, note: String, tint: Color) -> some View {
        let isSelected = selection == filter
        let count = counts.count(for: filter)
        return Button {
            selection = isSelected ? .all : filter
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: symbol).foregroundStyle(tint)
                    Text(filter.title).font(.callout.weight(.medium))
                    Spacer(minLength: 0)
                }
                Text("\(count)")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(note.isEmpty ? " " : note).font(.caption).foregroundStyle(Theme.metaText).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.md)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Color.accentColor.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5)
            }
        }
        .buttonStyle(.lopperCard)
        .disabled(count == 0 && !isSelected)
        .help(isSelected
            ? "Showing only this. Click to show everything again."
            : "\(filter.explanation) Click to show only these.")
        .accessibilityLabel("\(filter.title): \(count)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter by branch or repository", text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel("Filter by branch or repository")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.lopperIcon)
                    .help("Clear the filter")
                    .accessibilityLabel("Clear the filter")
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 6)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
    }
}

private struct NoMatches: View {
    let query: LocalOnlyQuery
    let reset: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.largeTitle).foregroundStyle(.secondary)
            Text("Nothing matches").font(.headline)
            Text(query.isSearching ? "No item matches \"\(query.trimmedSearch)\" with the current filter." : "Nothing of this kind is waiting.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Show everything", action: reset)
                .buttonStyle(.lopperSecondary)
                .controlSize(.small)
                .help("Clear the search and the filter.")
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.xl)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

// MARK: Repository section

private struct SectionCard: View {
    let section: LocalOnlySection
    let startsExpanded: Bool
    let limitsRows: Bool
    let initiallyOpen: Set<String>

    @Environment(AppModel.self) private var model
    @State private var expandedOverride: Bool?
    @State private var showingAll = false
    @State private var showsUntrackedOnly = false
    @State private var openItems: Set<String> = []
    @State private var didSeedOpen = false

    private var isExpanded: Bool { expandedOverride ?? startsExpanded }

    private var visibleItems: [LocalOnlyItem] {
        guard limitsRows, !showingAll else { return section.items }
        return Array(section.items.prefix(LocalOnlyPresenter.rowsBeforeShowMore))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider()
                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    ItemRow(item: item, isOpen: binding(for: item))
                    if index < visibleItems.count - 1 || hasFooter { Divider().padding(.leading, Theme.Spacing.md) }
                }
                footer
            }
        }
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .onAppear {
            guard !didSeedOpen else { return }
            didSeedOpen = true
            openItems = initiallyOpen
        }
    }

    private var hiddenCount: Int { max(0, section.items.count - visibleItems.count) }
    private var hasFooter: Bool { hiddenCount > 0 || showingAll && section.items.count > LocalOnlyPresenter.rowsBeforeShowMore || !section.untrackedOnly.isEmpty }

    private func binding(for item: LocalOnlyItem) -> Binding<Bool> {
        Binding(
            get: { openItems.contains(item.id) },
            set: { if $0 { openItems.insert(item.id) } else { openItems.remove(item.id) } })
    }

    private var header: some View {
        let counts = LocalOnlyPresenter.counts(of: section.all)
        return HStack(spacing: Theme.Spacing.sm) {
            Button { expandedOverride = !isExpanded } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 14)
                    Image(systemName: "shippingbox").foregroundStyle(.secondary)
                    Text(section.repoName).font(.headline)
                    Text(summaryLine(counts)).font(.caption).foregroundStyle(Theme.metaText).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(isExpanded ? "Hide this repository's items" : "Show this repository's items")
            .accessibilityLabel("\(section.repoName), \(summaryLine(counts))")
            .accessibilityHint(isExpanded ? "Collapses the list" : "Expands the list")

            if !section.pushCommands.isEmpty {
                Button { model.copyPushCommands(section) } label: {
                    Label(section.pushCommands.count == 1 ? "Copy push command" : "Copy \(section.pushCommands.count) push commands",
                          systemImage: "doc.on.doc")
                }
                .buttonStyle(.lopperSecondary)
                .controlSize(.small)
                .help("Copy one git push line per unpushed branch, to paste into a terminal. Lopper does not run them.")
            }
            Menu {
                Button("Open repository in Lopper") { model.openRepository(section.repoRoot.path) }
                Button("Show in Finder") { OpenActions.reveal(section.repoRoot) }
                Button("Open in Terminal") { OpenActions.openInTerminal(section.repoRoot) }
                Button("Copy path") { model.copyText(section.repoRoot.path, confirmation: "Copied the path") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.lopperIcon)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More for \(section.repoName): open it in Lopper, Finder or Terminal")
            .accessibilityLabel("More actions for \(section.repoName)")
        }
        .padding(Theme.Spacing.md)
        .help(RowMapper.abbreviated(section.repoRoot))
    }

    private func summaryLine(_ counts: LocalOnlyCounts) -> String {
        var parts: [String] = []
        if counts.notPushed > 0 { parts.append("\(counts.notPushed) not pushed") }
        if counts.uncommitted > 0 { parts.append("\(counts.uncommitted) uncommitted") }
        if counts.other > 0 { parts.append("\(counts.other) other") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var footer: some View {
        if hiddenCount > 0 {
            footerButton("Show \(hiddenCount) more", symbol: "chevron.down",
                         help: "Show the other \(Plural.count(hiddenCount, "item")) in \(section.repoName)") { showingAll = true }
        } else if showingAll && section.items.count > LocalOnlyPresenter.rowsBeforeShowMore {
            footerButton("Show fewer", symbol: "chevron.up", help: "Go back to the first few items") { showingAll = false }
        }
        if !section.untrackedOnly.isEmpty {
            if hiddenCount > 0 || showingAll && section.items.count > LocalOnlyPresenter.rowsBeforeShowMore { Divider() }
            footerButton(
                "\(Plural.count(section.untrackedOnly.count, "worktree")) with only untracked files",
                symbol: showsUntrackedOnly ? "chevron.up" : "chevron.down",
                help: "Files git has never seen, in worktrees where nothing tracked changed. Quieter than the rest, but still only here.") {
                showsUntrackedOnly.toggle()
            }
            if showsUntrackedOnly {
                ForEach(section.untrackedOnly) { item in
                    Divider().padding(.leading, Theme.Spacing.md)
                    ItemRow(item: item, isOpen: binding(for: item))
                }
            }
        }
    }

    private func footerButton(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: symbol).font(.caption.weight(.semibold))
                Text(title).font(.callout)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.accentText)
            .padding(Theme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
    }
}

// MARK: One item

private struct ItemRow: View {
    let item: LocalOnlyItem
    @Binding var isOpen: Bool
    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Button { isOpen.toggle() } label: { summary }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .help(isOpen ? "Hide what is in \(item.title)" : "Show what is in \(item.title)")
                    .accessibilityLabel("\(item.title), \(LocalOnlyKindStyle.label(item.kind)), \(item.detail)")
                    .accessibilityHint(isOpen ? "Hides the details" : "Shows the details")
                // The age and the three shortcuts share one spot, so every chevron sits in the same column.
                ZStack(alignment: .trailing) {
                    if let date = item.lastTouched {
                        Text(AgeFormat.long(from: date)).font(.caption).foregroundStyle(Theme.metaText)
                            .opacity(isHovering && !isOpen ? 0 : 1)
                    }
                    quickActions.opacity(isHovering && !isOpen ? 1 : 0)
                }
                .frame(width: 104, alignment: .trailing)
                chevron
            }
            .padding(Theme.Spacing.md)
            if isOpen { ItemDetail(item: item).padding(.horizontal, Theme.Spacing.md).padding(.bottom, Theme.Spacing.md) }
        }
        .background(Color.primary.opacity(isHovering ? 0.03 : 0))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var summary: some View {
        HStack(spacing: Theme.Spacing.md) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(item.title).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Text(LocalOnlyKindStyle.label(item.kind))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isUrgent ? Theme.cautionText : .secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background((isUrgent ? Color.orange : Color.secondary).opacity(0.14), in: Capsule())
                }
                Text(item.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.md)
        }
        .contentShape(Rectangle())
    }

    private var chevron: some View {
        Button { isOpen.toggle() } label: {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .frame(width: 16, height: 24)
        }
        .buttonStyle(.lopperIcon)
        .help(isOpen ? "Hide the details" : "Show the details")
        .accessibilityHidden(true)
    }

    private var isUrgent: Bool { item.kind == .unpushedCommits || item.kind == .detachedCommits }

    @ViewBuilder private var badge: some View {
        let showsCount = (item.kind == .unpushedCommits || item.kind == .detachedCommits) && item.count > 0
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill((isUrgent ? Color.orange : Color.secondary).opacity(0.14))
            if showsCount {
                VStack(spacing: 0) {
                    Text("\(item.count)").font(.data(.callout, weight: .semibold)).monospacedDigit()
                    Text(item.count == 1 ? "commit" : "commits").font(.system(size: 8.5, weight: .medium))
                }
                .foregroundStyle(Theme.cautionText)
            } else {
                Image(systemName: LocalOnlyKindStyle.symbol(item.kind)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 46, height: 38)
        .accessibilityHidden(true)
    }

    private var quickActions: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if item.pushCommand != nil {
                Button { model.copyPushCommand(item) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.lopperIcon)
                    .help("Copy the git push command for \(item.title). Lopper does not run it.")
                    .accessibilityLabel("Copy push command for \(item.title)")
            }
            Button { OpenActions.reveal(item.path ?? item.repoRoot) } label: { Image(systemName: "folder") }
                .buttonStyle(.lopperIcon)
                .help("Show \(item.path == nil ? "the repository" : "this worktree") in Finder")
                .accessibilityLabel("Show \(item.title) in Finder")
            Button { OpenActions.openInTerminal(item.path ?? item.repoRoot) } label: { Image(systemName: "terminal") }
                .buttonStyle(.lopperIcon)
                .help("Open a terminal in \(item.path == nil ? "the repository" : "this worktree")")
                .accessibilityLabel("Open \(item.title) in Terminal")
        }
    }
}

/// What opens under a row: what it means, the commits or files inside, and every action with its name on it.
private struct ItemDetail: View {
    let item: LocalOnlyItem
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(LocalOnlyKindStyle.guidance(item))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if LocalOnlyKindStyle.hasDetail(item.kind) { contents }
            actions
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .task { await model.loadLocalOnlyDetail(item) }
    }

    @ViewBuilder private var contents: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(LocalOnlyKindStyle.detailTitle(item.kind))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.metaText)
            if let detail = model.localOnlyDetails[item.id] {
                if detail.lines.isEmpty {
                    Text("Git has nothing to list for this one right now. Rescan to refresh.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(detail.lines.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.data(.caption)).lineLimit(1).truncationMode(.tail)
                        }
                        if detail.hiddenCount > 0 {
                            Text("and \(detail.hiddenCount) more").font(.caption).foregroundStyle(Theme.metaText)
                        }
                    }
                    .textSelection(.enabled)
                }
            } else {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Reading from git…").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actions: some View {
        FlowLayout(spacing: Theme.Spacing.sm) {
            if item.pushCommand != nil {
                Button { model.copyPushCommand(item) } label: { Label("Copy push command", systemImage: "arrow.up.doc") }
                    .buttonStyle(.lopperPrimary)
                    .help("Copy the git push line for \(item.title) to paste into a terminal. Lopper does not run it.")
            }
            Button { OpenActions.reveal(item.path ?? item.repoRoot) } label: { Label("Show in Finder", systemImage: "folder") }
                .buttonStyle(.lopperSecondary)
                .help("Reveal this folder in Finder")
            Button { OpenActions.openInTerminal(item.path ?? item.repoRoot) } label: { Label("Open in Terminal", systemImage: "terminal") }
                .buttonStyle(.lopperSecondary)
                .help("Open a terminal in this folder to commit, push or finish the operation")
            Button { model.openRepository(item.repoRoot.path) } label: { Label("Open repository", systemImage: "square.stack.3d.up") }
                .buttonStyle(.lopperSecondary)
                .help("See \(item.repoName) in Lopper, with its branches and worktrees")
            if let branch = item.branch {
                Button { model.copyText(branch, confirmation: "Copied the branch name") } label: {
                    Label("Copy name", systemImage: "textformat")
                }
                .buttonStyle(.lopperSecondary)
                .help("Copy \(branch)")
            }
        }
        .controlSize(.small)
    }
}
