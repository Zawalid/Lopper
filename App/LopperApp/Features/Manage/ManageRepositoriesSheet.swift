import SwiftUI
import Lopper

/// One place to decide what Lopper looks at: hide repositories one by one or a whole project folder at once, skip a
/// folder by name, bring things back, and change the folders that are scanned. Nothing here deletes anything from disk.
struct ManageRepositoriesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .repositories
    @State private var listing: Listing = .listed
    @State private var search = ""
    @State private var selection: Set<String> = []
    @State private var banner: Banner?

    enum Tab: String, CaseIterable, Identifiable {
        case repositories = "Repositories"
        case folders = "Folders"
        var id: Self { self }
    }

    enum Listing { case listed, hidden }

    struct Banner: Identifiable {
        let id = UUID()
        let message: String
        let undo: () -> Void
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let banner { BannerView(banner: banner, dismiss: { self.banner = nil }) }
            Divider()
            switch tab {
            case .repositories: repositoriesTab
            case .folders: foldersTab
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 680)
        .onChange(of: listing) { selection = [] }
        .onChange(of: tab) { selection = [] }
    }

    // MARK: Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Manage repositories").font(.title3.weight(.semibold))
            Text("Choose what Lopper looks at. Hiding or skipping something only changes Lopper's list: no file on your Mac is deleted, and you can bring everything back.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .help("Repositories: hide or show what was found. Folders: change where Lopper looks.")
                Spacer(minLength: 0)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.md) {
            if tab == .repositories {
                Text(selection.isEmpty ? "Tick repositories to hide several at once." : "\(selection.count) selected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Select all shown") { selection = Set(shownRepositories.map(\.id)) }
                    .buttonStyle(.lopperLink)
                    .disabled(shownRepositories.isEmpty)
                    .help("Tick every repository in the current list, including ones inside folded groups")
                if !selection.isEmpty {
                    Button("Clear") { selection = [] }
                        .buttonStyle(.lopperLink)
                        .help("Untick everything")
                }
            }
            Spacer()
            if tab == .repositories {
                Button(listing == .listed ? "Hide \(selection.count)" : "Show \(selection.count)") { applySelection() }
                    .buttonStyle(.lopperSecondary)
                    .disabled(selection.isEmpty)
                    .help(listing == .listed
                        ? "Stop listing the ticked repositories. Nothing is deleted."
                        : "Bring the ticked repositories back into Lopper")
            }
            Button("Done") { dismiss() }
                .buttonStyle(.lopperPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(Theme.Spacing.lg)
    }

    // MARK: Repositories

    private var source: [ManagedRepository] {
        listing == .listed ? model.listedRepositories : model.hiddenRepositories
    }

    private var shownRepositories: [ManagedRepository] {
        RepositoryManagerPresenter.groups(of: source, search: search).flatMap(\.repositories)
    }

    private var repositoriesTab: some View {
        // Each of these reads the scan, so they are read once per redraw and not once per use.
        let listed = model.listedRepositories
        let hidden = model.hiddenRepositories
        let groups = RepositoryManagerPresenter.groups(of: listing == .listed ? listed : hidden, search: search)
        let scannedFolders = model.settings.folders.filter(\.isEnabled).map { $0.path.canonicalized.path }
        return VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                ManageSearchField(text: $search)
                Picker("List", selection: $listing) {
                    Text("Listed (\(listed.count))").tag(Listing.listed)
                    Text("Hidden (\(hidden.count))").tag(Listing.hidden)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
                .help("Listed: what Lopper shows now. Hidden: what you asked it to ignore.")
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)

            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    ManageGroupsList(
                        groups: groups, listing: listing, scannedFolders: scannedFolders, selection: $selection,
                        onHide: { hide($0, label: $1) }, onShow: { show($0) }, onSkip: { skip($0) })
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.xl)
                }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: listing == .hidden ? "eye" : "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
            Text(emptyTitle).font(.headline)
            Text(emptyDetail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Spacing.xl)
    }

    private var emptyTitle: String {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { return "Nothing matches" }
        return listing == .hidden ? "Nothing is hidden" : "No repositories found yet"
    }

    private var emptyDetail: String {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty { return "Try a different name or folder." }
        return listing == .hidden
            ? "Repositories you hide show up here, so you can bring them back."
            : "Add a folder on the Folders tab, then rescan."
    }

    private func applySelection() {
        let chosen = source.filter { selection.contains($0.id) }
        if listing == .listed { hide(chosen, label: "") } else { show(chosen) }
    }

    private func hide(_ repositories: [ManagedRepository], label: String) {
        let roots = repositories.map(\.root)
        guard !roots.isEmpty else { return }
        model.hideRepositories(roots)
        selection.subtract(repositories.map(\.id))
        let what = Plural.count(roots.count, "repository", "repositories")
        banner = Banner(message: "Hid \(what)\(label). They are still on your Mac.") { model.showRepositories(roots) }
    }

    private func show(_ repositories: [ManagedRepository]) {
        let roots = repositories.map(\.root)
        guard !roots.isEmpty else { return }
        model.showRepositories(roots)
        selection.subtract(repositories.map(\.id))
        banner = Banner(message: "Showing \(Plural.count(roots.count, "repository", "repositories")) again.") {
            model.hideRepositories(roots)
        }
    }

    private func skip(_ group: ManagedGroup) {
        guard let first = group.repositories.first, model.skipFolderNamed(group.name, containing: first.root) else { return }
        let name = group.name
        banner = Banner(message: "Skipping folders named \"\(name)\" in future scans.") { model.stopSkippingFolderNamed(name) }
    }

    // MARK: Folders

    private var foldersTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("Folders Lopper looks in")
                    .font(.headline)
                if model.settings.folders.isEmpty {
                    Text("No folders yet. Add the folders that contain your projects.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.settings.folders, id: \.path) { folder in
                    ScannedFolderRow(folder: folder)
                    Divider()
                }
                HStack {
                    Button { FolderPicker.choose { model.addRoots($0) } } label: {
                        Label("Add folder…", systemImage: "plus")
                    }
                    .buttonStyle(.lopperSecondary)
                    .help("Choose another folder that contains projects")
                    Button("Run setup again…") {
                        dismiss()
                        model.restartOnboarding()
                    }
                    .buttonStyle(.lopperLink)
                    .help("Find folders on this Mac, or pick new ones, from the start")
                }
                Text("To leave out a project folder you found by mistake, open the Repositories tab and choose Skip folders named… on its group.")
                    .font(.caption)
                    .foregroundStyle(Theme.metaText)
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Pieces

private struct BannerView: View {
    let banner: ManageRepositoriesSheet.Banner
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(banner.message).font(.callout)
            Spacer(minLength: 0)
            Button("Undo") {
                banner.undo()
                dismiss()
            }
            .buttonStyle(.lopperLink)
            .help("Put it back the way it was")
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.lopperIcon)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Color.green.opacity(0.1))
        .task(id: banner.id) {
            try? await Task.sleep(for: .seconds(12))
            dismiss()
        }
    }
}

private struct ManageSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search repositories or folders", text: $text)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search repositories or folders")
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.lopperIcon)
                    .help("Clear the search")
                    .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 6)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
    }
}

/// The groups inside the scroll view, separate so it can be rendered offscreen.
struct ManageGroupsList: View {
    let groups: [ManagedGroup]
    let listing: ManageRepositoriesSheet.Listing
    /// Canonical paths of the enabled scanned folders, read once so no group has to resolve them again.
    var scannedFolders: [String] = []
    @Binding var selection: Set<String>
    let onHide: ([ManagedRepository], String) -> Void
    let onShow: ([ManagedRepository]) -> Void
    let onSkip: (ManagedGroup) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            ForEach(groups) { group in
                GroupSection(
                    group: group, listing: listing, scannedFolders: scannedFolders, selection: $selection,
                    onHide: onHide, onShow: onShow, onSkip: onSkip)
            }
        }
    }
}

private struct GroupSection: View {
    let group: ManagedGroup
    let listing: ManageRepositoriesSheet.Listing
    let scannedFolders: [String]
    @Binding var selection: Set<String>
    let onHide: ([ManagedRepository], String) -> Void
    let onShow: ([ManagedRepository]) -> Void
    let onSkip: (ManagedGroup) -> Void

    @Environment(AppModel.self) private var model

    private var ids: Set<String> { Set(group.repositories.map(\.id)) }
    private var allSelected: Bool { !ids.isEmpty && ids.isSubset(of: selection) }
    private var canSkip: Bool {
        guard listing == .listed, RepositoryManagerPresenter.canSkip(folderNamed: group.name),
            let first = group.repositories.first else { return false }
        return scannedFolders.contains { first.root.path == $0 || first.root.path.hasPrefix($0 + "/") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ForEach(Array(group.repositories.enumerated()), id: \.element.id) { index, repository in
                RepositoryRow(repository: repository, listing: listing, selection: $selection, onHide: onHide, onShow: onShow)
                if index < group.repositories.count - 1 { Divider().padding(.leading, 44) }
            }
        }
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Toggle(isOn: Binding(
                get: { allSelected },
                set: { on in if on { selection.formUnion(ids) } else { selection.subtract(ids) } }
            )) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help("Tick every repository in \(group.name)")
            .accessibilityLabel("Select all in \(group.name)")
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text(group.name).font(.headline)
            Text(RowMapper.abbreviated(group.folder)).font(.caption).foregroundStyle(Theme.metaText)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            Text(Plural.count(group.repositories.count, "repository", "repositories"))
                .font(.caption).foregroundStyle(Theme.metaText)
            if listing == .listed {
                Button("Hide all \(group.repositories.count)") { onHide(group.repositories, " in \(group.name)") }
                    .buttonStyle(.lopperSecondary)
                    .controlSize(.small)
                    .help("Stop listing every repository in \(group.name). Nothing is deleted.")
            } else {
                Button("Show all \(group.repositories.count)") { onShow(group.repositories) }
                    .buttonStyle(.lopperSecondary)
                    .controlSize(.small)
                    .help("Bring every repository in \(group.name) back")
            }
            Menu {
                if canSkip {
                    Button("Skip folders named \"\(group.name)\" in future scans") { onSkip(group) }
                }
                Button("Show in Finder") { OpenActions.reveal(group.folder) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.lopperIcon)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More for \(group.name)")
            .accessibilityLabel("More actions for \(group.name)")
        }
        .padding(Theme.Spacing.md)
    }
}

private struct RepositoryRow: View {
    let repository: ManagedRepository
    let listing: ManageRepositoriesSheet.Listing
    @Binding var selection: Set<String>
    let onHide: ([ManagedRepository], String) -> Void
    let onShow: ([ManagedRepository]) -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Toggle(isOn: Binding(
                get: { selection.contains(repository.id) },
                set: { on in if on { selection.insert(repository.id) } else { selection.remove(repository.id) } }
            )) { EmptyView() }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(repository.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(repository.name).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(repository.problem == nil ? Theme.metaText : Theme.cautionText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Group {
                if listing == .listed {
                    Button("Hide") { onHide([repository], "") }
                        .help("Stop listing \(repository.name). Nothing is deleted.")
                } else {
                    Button("Show") { onShow([repository]) }
                        .help("Bring \(repository.name) back into Lopper")
                }
            }
            .buttonStyle(.lopperSecondary)
            .controlSize(.small)
            .opacity(isHovering ? 1 : 0)
            Button { OpenActions.reveal(repository.root) } label: { Image(systemName: "folder") }
                .buttonStyle(.lopperIcon)
                .help("Show \(repository.name) in Finder")
                .accessibilityLabel("Show \(repository.name) in Finder")
                .opacity(isHovering ? 1 : 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(isHovering ? 0.03 : 0))
        .onHover { isHovering = $0 }
        .help(repository.root.path)
    }

    private var detail: String {
        if let problem = repository.problem { return "Could not be read: \(problem)" }
        if listing == .hidden { return "Hidden. Not scanned." }
        return Plural.count(repository.items, "item")
    }
}
