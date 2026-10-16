import SwiftUI
import Lopper

enum DiskPalette {
    static func color(for kind: ArtifactKind) -> Color {
        switch kind {
        case .packages: .orange
        case .frameworkCache: .yellow
        case .buildOutput: Color.accentColor
        case .languageBuild: Color(red: 0.86, green: 0.45, blue: 0.40)
        case .pythonEnvironment: .green
        case .cache: .teal
        case .other: .gray
        }
    }
}

/// Every generated folder as a block sized by its bytes, grouped by project, so the big ones are obvious at a
/// glance. Click a block for its details and actions.
struct DiskMapView: View {
    let projects: [DiskProject]
    let caches: [DiskArtifact]
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedID: String?

    private struct Group: Identifiable {
        let id: String
        let title: String
        let artifacts: [DiskArtifact]
        var bytes: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }
    }

    private var projectGroups: [Group] {
        projects.map { Group(id: $0.id, title: $0.name, artifacts: $0.artifacts) }
    }

    private var cacheGroup: Group? {
        caches.isEmpty ? nil : Group(id: "developer-caches", title: "Developer caches", artifacts: caches)
    }

    private var allArtifacts: [DiskArtifact] { projects.flatMap(\.artifacts) + caches }
    private var selected: DiskArtifact? { allArtifacts.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let size = proxy.size
                // Tool caches are not part of any project and are often bigger than all of them together, so
                // they get their own strip instead of shrinking every project to a sliver.
                let stripHeight = cacheGroup == nil ? 0 : min(150, size.height * 0.28)
                let gap: CGFloat = cacheGroup == nil ? 0 : Theme.Spacing.md
                VStack(alignment: .leading, spacing: gap) {
                    if projectGroups.isEmpty {
                        Text("No project folders match.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        map(
                            groups: projectGroups,
                            in: CGRect(x: 0, y: 0, width: size.width, height: size.height - stripHeight - gap))
                    }
                    if let cacheGroup {
                        map(groups: [cacheGroup], in: CGRect(x: 0, y: 0, width: size.width, height: stripHeight))
                    }
                }
            }
            .padding(Theme.Spacing.lg)
            Divider()
            footer
        }
    }

    private func map(groups: [Group], in bounds: CGRect) -> some View {
        let cells = Treemap.layout(groups.map { ($0.id, Double($0.bytes)) }, in: bounds)
        return ZStack(alignment: .topLeading) {
            ForEach(cells, id: \.id) { cell in
                if let group = groups.first(where: { $0.id == cell.id }) {
                    groupView(group, rect: cell.rect)
                }
            }
        }
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
    }

    private func groupView(_ group: Group, rect: CGRect) -> some View {
        let outer = rect.insetBy(dx: 2, dy: 2)
        let showsTitle = outer.height > 54 && outer.width > 80
        let headerHeight: CGFloat = showsTitle ? 20 : 0
        let inner = CGRect(
            x: 4, y: headerHeight + 2, width: max(0, outer.width - 8), height: max(0, outer.height - headerHeight - 6))
        let tiles = Treemap.layout(group.artifacts.map { ($0.id, Double($0.bytes)) }, in: inner)

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10))
            if showsTitle {
                HStack(spacing: 6) {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if outer.width > 170 {
                        Text(SizeFormat.string(group.bytes))
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .frame(width: outer.width, alignment: .leading)
            }
            ForEach(tiles, id: \.id) { tile in
                if let artifact = group.artifacts.first(where: { $0.id == tile.id }) {
                    tileView(artifact, rect: tile.rect)
                }
            }
        }
        .frame(width: outer.width, height: outer.height, alignment: .topLeading)
        .offset(x: outer.minX, y: outer.minY)
    }

    private func tileView(_ artifact: DiskArtifact, rect: CGRect) -> some View {
        let tile = rect.insetBy(dx: 1, dy: 1)
        let color = artifact.removal.isOffered ? DiskPalette.color(for: artifact.kind) : Color.gray
        let isSelected = selectedID == artifact.id
        return RoundedRectangle(cornerRadius: 5)
            .fill(color.opacity(artifact.removal.isOffered ? (colorScheme == .dark ? 0.75 : 0.62) : 0.35))
            .overlay(alignment: .topLeading) {
                if tile.width > 54 && tile.height > 30 {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(artifact.name).font(.caption2.weight(.semibold)).lineLimit(1)
                        Text(SizeFormat.string(artifact.bytes)).font(.caption2).opacity(0.85).lineLimit(1)
                    }
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color.black.opacity(0.82))
                    .padding(4)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected ? (colorScheme == .dark ? Color.white : Color.black) : .clear, lineWidth: 2))
            .frame(width: max(0, tile.width), height: max(0, tile.height))
            .offset(x: tile.minX, y: tile.minY)
            .contentShape(Rectangle())
            .onTapGesture { selectedID = artifact.id }
            .help("\(artifact.name), \(SizeFormat.string(artifact.bytes))")
            .accessibilityLabel("\(artifact.name), \(SizeFormat.string(artifact.bytes))")
            .contextMenu {
                if artifact.removal.isOffered {
                    Button("Clear…") { model.beginClear(artifact: artifact) }
                }
                Button("Reveal in Finder") { OpenActions.reveal(artifact.path) }
            }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        if let artifact = selected {
            HStack(spacing: Theme.Spacing.md) {
                Circle().fill(DiskPalette.color(for: artifact.kind)).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(artifact.name) in \(artifact.checkoutRoot.lastPathComponent)")
                        .font(.callout.weight(.semibold))
                    Text(detail(artifact)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: Theme.Spacing.md)
                Text(SizeFormat.string(artifact.bytes)).font(.callout.monospacedDigit().weight(.medium))
                Button("Reveal") { OpenActions.reveal(artifact.path) }
                    .buttonStyle(.lopperSecondary).controlSize(.small)
                Button("Clear…") { model.beginClear(artifact: artifact) }
                    .buttonStyle(.lopperPrimary).controlSize(.small)
                    .disabled(!artifact.removal.isOffered || model.clean != nil || model.diskClear != nil)
            }
            .padding(Theme.Spacing.md)
        } else {
            legend
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
        }
    }

    private func detail(_ artifact: DiskArtifact) -> String {
        switch artifact.removal {
        case .offered(let how): "\(artifact.kind.title). Comes back with \(how)."
        case .blocked(let reason): reason
        }
    }

    private var legend: some View {
        let kinds = Array(Set(allArtifacts.map(\.kind))).sorted { $0.title < $1.title }
        return HStack(spacing: Theme.Spacing.md) {
            ForEach(kinds, id: \.self) { kind in
                HStack(spacing: 5) {
                    Circle().fill(DiskPalette.color(for: kind)).frame(width: 9, height: 9)
                    Text(kind.title).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text("Click a block for details. Grey blocks are not offered.")
                .font(.caption).foregroundStyle(Theme.metaText)
        }
    }
}
