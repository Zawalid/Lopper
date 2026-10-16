import SwiftUI
import Lopper

/// Replaces the content when Lopper cannot do anything useful: no git, or none of the chosen folders can be read.
struct SetupIssueView: View {
    let issue: SetupIssue
    @Environment(AppModel.self) private var model
    @State private var checking = false

    private var blocked: [(FolderSetting, FolderAccess)] {
        model.unreadableFolders.map { ($0, model.access(of: $0.path)) }
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: issue == .gitMissing ? "wrench.and.screwdriver" : "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: Theme.Spacing.sm) {
                Text(SetupGuide.title(for: issue, folders: blocked)).font(.title2.weight(.semibold))
                Text(SetupGuide.message(for: issue, folders: blocked))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if issue == .foldersUnreadable { folderList }
            actions
        }
        .frame(maxWidth: 440)
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await recheck() }
        }
    }

    private var folderList: some View {
        VStack(spacing: 0) {
            ForEach(blocked, id: \.0.path) { folder, access in
                HStack(spacing: Theme.Spacing.md) {
                    Text(RowMapper.abbreviated(folder.path)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Theme.Spacing.md)
                    Text(SetupGuide.reason(for: access)).font(.caption).foregroundStyle(.secondary)
                    if access != .denied {
                        Button { model.removeRoot(folder.path) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.lopperIcon)
                            .help("Stop looking in this folder")
                            .accessibilityLabel("Remove \(folder.path.lastPathComponent)")
                    }
                }
                .padding(.vertical, Theme.Spacing.sm)
                .padding(.horizontal, Theme.Spacing.md)
            }
        }
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.controlRadius))
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: Theme.Spacing.md) {
            switch issue {
            case .gitMissing:
                Button("Install command line tools") { SetupActions.installCommandLineTools() }
                    .buttonStyle(.lopperPrimary)
            case .foldersUnreadable:
                if blocked.contains(where: { $0.1 == .denied }) {
                    Button("Open Privacy settings") { OpenActions.open(SetupActions.filesAndFoldersSettings) }
                        .buttonStyle(.lopperPrimary)
                } else {
                    Button("Choose folders") { FolderPicker.choose { model.addRoots($0) } }
                        .buttonStyle(.lopperPrimary)
                }
            }
            Button(checking ? "Checking…" : "Check again") { Task { await recheck() } }
                .buttonStyle(.lopperSecondary)
                .disabled(checking)
        }
        if issue == .foldersUnreadable, blocked.contains(where: { $0.1 == .denied }) {
            Button("Allow full disk access instead") { OpenActions.open(SetupActions.fullDiskAccessSettings) }
                .buttonStyle(.lopperLink)
        }
    }

    private func recheck() async {
        guard !checking else { return }
        checking = true
        await model.recheckSetup()
        checking = false
    }
}
