import SwiftUI
import Lopper

struct DiskView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        DiskContent()
            .navigationTitle("Disk")
            .navigationSubtitle(subtitle)
            .searchable(text: $model.diskSearchText, placement: .toolbar, prompt: "Search projects and folders")
    }

    private var subtitle: String {
        let totals = model.diskTotals
        guard totals.folders > 0 else { return "" }
        return "\(SizeFormat.string(totals.clearableBytes)) can be cleared"
    }
}

/// The page body without toolbar, so it can be rendered offscreen.
struct DiskContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.diskPageState {
            case .needsFolders:
                EmptyState(
                    symbol: "folder.badge.plus", title: "Choose your project folders",
                    message: "Lopper finds the folders your projects regenerate (node_modules, build output) inside them.",
                    actionTitle: "Choose folders", action: { FolderPicker.choose { model.setRoots($0) } })
            case .scanning:
                VStack(spacing: Theme.Spacing.md) {
                    ProgressView().controlSize(.large)
                    Text("Looking for generated folders…").foregroundStyle(.secondary)
                }
            case .nothingFound(let projects):
                EmptyState(
                    symbol: "checkmark.circle", title: "Nothing to clear",
                    message: "Lopper looked in \(Plural.count(projects, "repository", "repositories")) and found no "
                        + "generated folders it can bring back.")
            case .ready:
                DiskReady()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DiskReady: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingDelete = false

    private var cacheBytes: Int64 { model.developerCaches.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        let projects = model.visibleDiskProjects
        let waiting = model.trashedTotals
        VStack(spacing: 0) {
            if waiting.folders > 0 {
                Banner(
                    symbol: "trash",
                    message: "\(SizeFormat.string(waiting.bytes)) from \(Plural.count(waiting.folders, "folder")) "
                        + "is still in the Trash and keeps using disk until it is deleted.",
                    actionTitle: "Delete for good", action: { confirmingDelete = true })
                    .padding([.horizontal, .top], Theme.Spacing.lg)
            }
            DiskTotalsStrip()
            if let space = model.volumeSpace {
                VolumeBar(space: space, reclaimable: model.diskTotals.clearableBytes + cacheBytes)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.sm)
            }
            if let top = model.diskDuplicates.first, !model.diskUntouchedOnly {
                DuplicateInsight(duplicate: top)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.sm)
            }
            Controls()
            Divider()
            if projects.isEmpty {
                EmptyState(
                    symbol: "line.3.horizontal.decrease.circle", title: "Nothing matches",
                    message: model.diskUntouchedOnly
                        ? "No project has gone \(model.settings.staleDays) days without an edit."
                        : "Try a different search.")
            } else if model.diskGrouping == .map {
                DiskMapView(
                    projects: projects,
                    caches: model.diskUntouchedOnly ? [] : model.developerCaches)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        switch model.diskGrouping {
                        case .project:
                            ForEach(projects) { ProjectCard(project: $0) }
                        case .kind:
                            ForEach(model.diskKindGroups) { KindCard(group: $0) }
                        case .map:
                            EmptyView()
                        }
                        if !model.developerCaches.isEmpty && !model.diskUntouchedOnly {
                            DeveloperCachesCard()
                        }
                    }
                    .padding(Theme.Spacing.lg)
                }
            }
        }
        .confirmationDialog(
            "Delete \(Plural.count(waiting.folders, "folder")) for good?", isPresented: $confirmingDelete
        ) {
            Button("Delete \(SizeFormat.string(waiting.bytes)) for good", role: .destructive) {
                model.deleteTrashedForGood()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These are the folders Lopper moved to the Trash. They are removed from the Trash and can no "
                + "longer be restored. Everything else in the Trash is left alone.")
        }
    }
}

/// How full the disk is, with the part Lopper could give back marked at the end of the used space.
private struct VolumeBar: View {
    let space: VolumeSpace
    let reclaimable: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                let total = Double(max(space.total, 1))
                let usedWidth = proxy.size.width * Double(space.used) / total
                let reclaimWidth = min(usedWidth, proxy.size.width * Double(reclaimable) / total)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(Color.blue.opacity(0.65)).frame(width: max(4, usedWidth))
                    if reclaimWidth > 1 {
                        Capsule().fill(Color.green)
                            .frame(width: max(4, reclaimWidth))
                            .offset(x: max(0, usedWidth - reclaimWidth))
                    }
                }
            }
            .frame(height: 8)
            HStack {
                Text("\(SizeFormat.string(space.available)) free of \(SizeFormat.string(space.total))")
                Spacer()
                if reclaimable > 0 {
                    Label("\(SizeFormat.string(reclaimable)) can be given back", systemImage: "circle.fill")
                        .foregroundStyle(Theme.positiveText)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The cheapest saving on the page, said in one line: copies that worktrees hold of what the main folder has.
private struct DuplicateInsight: View {
    let duplicate: DiskDuplicate
    @Environment(AppModel.self) private var model

    var body: some View {
        Banner(
            symbol: "square.on.square",
            message: "\(duplicate.repoName) holds \(duplicate.copies) copies of \(duplicate.name), "
                + "\(SizeFormat.string(duplicate.totalBytes)) together. The "
                + "\(duplicate.clearableInWorktrees.count) in worktrees can go: "
                + "\(SizeFormat.string(duplicate.freeableBytes)).",
            actionTitle: "Clear the \(duplicate.clearableInWorktrees.count)",
            action: { model.beginClear(duplicate: duplicate) })
    }
}

private struct DeveloperCachesCard: View {
    @Environment(AppModel.self) private var model
    @State private var isExpanded = false

    var body: some View {
        let caches = model.developerCaches
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.metaText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12)
                        Image(systemName: "externaldrive.badge.icloud").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Developer caches").font(.callout.weight(.semibold))
                            Text("Outside your projects. Each tool rebuilds its own.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer(minLength: Theme.Spacing.md)
                Text(SizeFormat.string(caches.reduce(0) { $0 + $1.bytes }))
                    .font(.callout.monospacedDigit().weight(.medium))
                Button("Clear \(caches.count)") { model.beginClearDeveloperCaches() }
                    .buttonStyle(.lopperSecondary)
                    .controlSize(.small)
                    .disabled(model.clean != nil || model.diskClear != nil)
            }
            .padding(Theme.Spacing.md)

            if isExpanded {
                Divider().padding(.horizontal, Theme.Spacing.md)
                VStack(spacing: 0) {
                    ForEach(caches) { cache in
                        HStack(spacing: Theme.Spacing.md) {
                            Image(systemName: "memorychip").foregroundStyle(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(cache.name).font(.callout)
                                if case .offered(let how) = cache.removal {
                                    Text("Comes back with \(how)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: Theme.Spacing.md)
                            Text(SizeFormat.string(cache.bytes))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button("Clear") { model.beginClear(artifact: cache) }
                                .buttonStyle(.lopperSecondary)
                                .controlSize(.small)
                                .disabled(model.clean != nil || model.diskClear != nil)
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .contextMenu {
                            Button("Reveal in Finder") { OpenActions.reveal(cache.path) }
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

private struct DiskTotalsStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let totals = model.diskTotals
        VStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.lg) {
                StatTile(
                    title: "On disk", value: SizeFormat.string(totals.footprint), symbol: "internaldrive",
                    tint: .blue)
                StatTile(
                    title: "Generated folders", value: SizeFormat.string(totals.buildBytes),
                    symbol: "shippingbox", tint: .orange)
                StatTile(
                    title: "Safe to clear", value: SizeFormat.string(totals.clearableBytes),
                    symbol: "checkmark.circle", tint: VerdictKind.safe.tint,
                    action: totals.clearableBytes > 0 ? { model.beginClearAllClearable() } : nil)
                StatTile(
                    title: "Untouched \(model.settings.staleDays)+ days",
                    value: SizeFormat.string(totals.untouchedBytes), symbol: "clock",
                    tint: .secondary,
                    action: totals.untouchedBytes > 0 ? { model.beginClearUntouched() } : nil)
            }
            .statStrip()
            if model.artifactPhase == .scanning || model.isScanning {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Still measuring. Sizes fill in as they arrive.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.sm)
    }
}

private struct Controls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let visible = model.visibleDiskProjects
        let clearable = visible.flatMap(\.clearable)
        HStack(spacing: Theme.Spacing.md) {
            Picker("Group", selection: $model.diskGrouping) {
                ForEach(DiskGrouping.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            .help("Group by project or kind of folder, or see everything as a map")

            Toggle("Untouched \(model.settings.staleDays)+ days", isOn: $model.diskUntouchedOnly)
                .toggleStyle(.checkbox)
                .help("Only projects nobody has edited for \(model.settings.staleDays) days")

            Spacer(minLength: 0)

            Button(clearable.isEmpty
                ? "Nothing to clear"
                : "Clear \(Plural.count(clearable.count, "folder")), \(SizeFormat.string(clearable.reduce(0) { $0 + $1.bytes }))") {
                model.beginClearAllClearable()
            }
            .buttonStyle(.lopperPrimary)
            .disabled(clearable.isEmpty || model.clean != nil || model.diskClear != nil)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }
}

// MARK: Project cards

private struct ProjectCard: View {
    let project: DiskProject
    @Environment(AppModel.self) private var model
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider().padding(.horizontal, Theme.Spacing.md)
                VStack(spacing: 0) {
                    ForEach(project.artifacts) { FolderRow(artifact: $0, showsProject: false) }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.md) {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.metaText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12)
                        Image(systemName: project.isWorktree ? "rectangle.stack" : "folder")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.name).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(project.name), \(SizeFormat.string(project.buildBytes)) generated")

                Spacer(minLength: Theme.Spacing.md)

                Text(SizeFormat.string(project.buildBytes))
                    .font(.callout.monospacedDigit().weight(.medium))

                Button(project.clearable.isEmpty ? "Nothing to clear" : project.clearTitle) {
                    model.beginClear(project: project.id)
                }
                .buttonStyle(.lopperSecondary)
                .controlSize(.small)
                .disabled(project.clearable.isEmpty || model.clean != nil || model.diskClear != nil)
            }
            SplitBar(source: project.sourceBytes, build: project.buildBytes)
        }
        .padding(Theme.Spacing.md)
    }

    private var detail: String {
        var parts: [String] = []
        parts.append(project.isWorktree ? "Worktree" : "Main folder")
        if let edited = project.lastEdited {
            parts.append("edited \(AgeFormat.short(from: edited, to: model.clock()))\(AgeFormat.short(from: edited, to: model.clock()) == "today" ? "" : " ago")")
        }
        parts.append(Plural.count(project.artifacts.count, "folder"))
        if !project.blocked.isEmpty { parts.append("\(project.blocked.count) not offered") }
        return parts.joined(separator: " · ")
    }
}

/// How much of a folder is the project itself and how much was generated.
private struct SplitBar: View {
    let source: Int64?
    let build: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { proxy in
                let total = Double((source ?? 0) + build)
                let fraction = total > 0 ? Double(build) / total : 1
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(source == nil ? 0.12 : 0.25))
                    Capsule().fill(Color.orange)
                        .frame(width: max(4, proxy.size.width * fraction))
                }
            }
            .frame(height: 6)
            if let source {
                Text("\(SizeFormat.string(build)) generated · \(SizeFormat.string(source)) your files")
                    .font(.caption2).foregroundStyle(Theme.metaText)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct FolderRow: View {
    let artifact: DiskArtifact
    let showsProject: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: Self.symbol(artifact.kind))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(relativePath).font(.data()).lineLimit(1).truncationMode(.middle)
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: Theme.Spacing.md)
            Text(SizeFormat.string(artifact.bytes))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button("Clear") { model.beginClear(artifact: artifact) }
                .buttonStyle(.lopperSecondary)
                .controlSize(.small)
                .disabled(!artifact.removal.isOffered || model.clean != nil || model.diskClear != nil)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .contextMenu {
            Button("Reveal in Finder") { OpenActions.reveal(artifact.path) }
            Button("Copy path") { model.copy(artifact.path.path, confirming: "Copied path") }
        }
    }

    private var relativePath: String {
        let base = artifact.checkoutRoot.standardizedFileURL.path
        let path = artifact.path.standardizedFileURL.path
        let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : artifact.name
        return showsProject ? "\(artifact.checkoutRoot.lastPathComponent) / \(relative)" : relative
    }

    private var note: String {
        switch artifact.removal {
        case .offered(let how): "\(artifact.kind.title). Comes back with \(how)."
        case .blocked(let reason): reason
        }
    }

    static func symbol(_ kind: ArtifactKind) -> String {
        switch kind {
        case .packages: "shippingbox"
        case .frameworkCache: "bolt"
        case .buildOutput: "hammer"
        case .languageBuild: "wrench.and.screwdriver"
        case .pythonEnvironment: "leaf"
        case .cache: "memorychip"
        case .other: "folder"
        }
    }
}

// MARK: Kind cards

private struct KindCard: View {
    let group: DiskKindGroup
    @Environment(AppModel.self) private var model
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.metaText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12)
                        Image(systemName: FolderRow.symbol(group.kind)).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.kind.title).font(.callout.weight(.semibold))
                            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: Theme.Spacing.md)

                Text(SizeFormat.string(group.bytes)).font(.callout.monospacedDigit().weight(.medium))
                Button(group.clearable.isEmpty ? "Nothing to clear" : "Clear \(group.clearable.count)") {
                    model.beginClear(kind: group.kind)
                }
                .buttonStyle(.lopperSecondary)
                .controlSize(.small)
                .disabled(group.clearable.isEmpty || model.clean != nil || model.diskClear != nil)
            }
            .padding(Theme.Spacing.md)

            if isExpanded {
                Divider().padding(.horizontal, Theme.Spacing.md)
                VStack(spacing: 0) {
                    ForEach(group.artifacts) { FolderRow(artifact: $0, showsProject: true) }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }

    private var detail: String {
        var text = Plural.count(group.artifacts.count, "folder")
        if !group.regenerateHint.isEmpty { text += " · comes back with \(group.regenerateHint)" }
        return text
    }
}
