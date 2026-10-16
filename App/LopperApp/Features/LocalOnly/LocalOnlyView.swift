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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            header
            ForEach(model.localOnlyGroups) { group in
                GroupCard(group: group)
            }
        }
        .padding(32)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(LocalOnlyKindStyle.headline(model.localOnlySummary)).font(.title3.weight(.semibold))
            Text("If this Mac or one of these folders were lost, this work would be lost with it. "
                + "Lopper never removes anything on this page, and never pushes for you.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct GroupCard: View {
    let group: LocalOnlyGroup
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "shippingbox").foregroundStyle(.secondary)
                Text(group.repoName).font(.headline)
                Text(RowMapper.abbreviated(group.repoRoot))
                    .font(.caption).foregroundStyle(Theme.metaText)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.md)
            Divider()
            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                ItemRow(item: item)
                if index < group.items.count - 1 { Divider().padding(.leading, Theme.Spacing.md) }
            }
        }
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}

private struct ItemRow: View {
    let item: LocalOnlyItem
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Image(systemName: LocalOnlyKindStyle.symbol(item.kind))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(item.title).font(.system(.body, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Text(LocalOnlyKindStyle.label(item.kind))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
                Text(item.detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.md)
            if let date = item.lastTouched {
                Text(AgeFormat.short(from: date)).font(.caption).foregroundStyle(Theme.metaText)
                    .help("Last activity")
            }
            actions
        }
        .padding(Theme.Spacing.md)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if item.pushCommand != nil {
                Button { model.copyPushCommand(item) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.lopperIcon)
                    .help("Copy the git push command. Lopper does not run it.")
                    .accessibilityLabel("Copy push command for \(item.title)")
            }
            Button { OpenActions.reveal(item.path ?? item.repoRoot) } label: { Image(systemName: "folder") }
                .buttonStyle(.lopperIcon)
                .help("Show in Finder")
                .accessibilityLabel("Show \(item.title) in Finder")
            Button { OpenActions.openInTerminal(item.path ?? item.repoRoot) } label: { Image(systemName: "terminal") }
                .buttonStyle(.lopperIcon)
                .help("Open in Terminal")
                .accessibilityLabel("Open \(item.title) in Terminal")
        }
    }
}
