import SwiftUI
import Lopper

struct FoldersPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneScaffold {
            Section {
                if model.settings.folders.isEmpty {
                    Text("No folders yet. Add the folders that contain your projects.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.settings.folders, id: \.path) { folder in
                    FolderRow(folder: folder)
                }
                Button("Add folder…") { FolderPicker.choose { model.addRoots($0) } }
            } header: {
                Text("Folders Lopper looks in")
            }

            Section {
                Stepper(
                    "Search depth: \(model.settings.scanDepth)",
                    value: Binding(
                        get: { model.settings.scanDepth },
                        set: { value in model.updateSettings { $0.scanDepth = value } }),
                    in: 1...8)
            } footer: {
                Text("How many levels below each folder Lopper searches for repositories.")
            }
        }
    }
}

private struct FolderRow: View {
    let folder: FolderSetting
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Toggle(isOn: Binding(
                    get: { folder.isEnabled },
                    set: { isOn in change { $0.isEnabled = isOn } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RowMapper.abbreviated(folder.path)).lineLimit(1).truncationMode(.middle)
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    model.removeRoot(folder.path)
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.lopperIcon)
                .help("Stop looking in this folder")
                .accessibilityLabel("Remove \(folder.path.lastPathComponent)")
            }
            if folder.isEnabled {
                DisclosureGroup("Skip folders matching") {
                    TagListEditor(
                        tags: Binding(
                            get: { folder.excludePatterns },
                            set: { value in change { $0.excludePatterns = value } }),
                        prompt: "legacy-*, vendor")
                    .padding(.top, Theme.Spacing.xs)
                }
                .font(.callout)
            }
        }
    }

    private var detail: String {
        guard folder.isEnabled else { return "Paused" }
        let count = model.repositoryCount(inFolder: folder.path)
        return Plural.count(count, "repository", "repositories")
    }

    private func change(_ edit: @escaping (inout FolderSetting) -> Void) {
        model.updateSettings { settings in
            if let index = settings.folders.firstIndex(where: { $0.path == folder.path }) {
                edit(&settings.folders[index])
            }
        }
    }
}
