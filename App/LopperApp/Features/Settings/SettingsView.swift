import SwiftUI
import ServiceManagement
import Lopper

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("editorBundleID") private var editorBundleID = EditorChoice.vscode.rawValue
    @AppStorage("showCountInMenuBar") private var showCountInMenuBar = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var protectedText = ""

    var body: some View {
        Form {
            Section("Folders") {
                ForEach(model.settings.roots, id: \.self) { root in
                    HStack {
                        Label(RowMapper.abbreviated(root), systemImage: "folder")
                        Spacer()
                        Button {
                            model.removeRoot(root)
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(root.lastPathComponent)")
                    }
                }
                Button("Add folder…") {
                    FolderPicker.choose { model.addRoots($0) }
                }
                Stepper(
                    "Search depth: \(model.settings.scanDepth)",
                    value: Binding(
                        get: { model.settings.scanDepth },
                        set: { value in model.updateSettings { $0.scanDepth = value } }),
                    in: 1...8)
            }

            Section("Safety") {
                TextField("Protected branches", text: $protectedText, prompt: Text("main, develop, release/*"))
                    .onSubmit { commitProtected() }
                    .onAppear { protectedText = model.settings.protectedPatterns.joined(separator: ", ") }
                Stepper(
                    "Keep removals restorable for \(model.settings.trashRetentionDays) days",
                    value: Binding(
                        get: { model.settings.trashRetentionDays },
                        set: { value in model.updateSettings { $0.trashRetentionDays = value } }),
                    in: 1...365)
                let throwaways = model.settings.repoDisposableNames.sorted { $0.key < $1.key }
                if throwaways.isEmpty {
                    Text("Files you mark as throwaway in a repository appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(throwaways, id: \.key) { path, names in
                        LabeledContent(URL(fileURLWithPath: path).lastPathComponent) {
                            Text(names.joined(separator: ", ")).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Tools") {
                Picker("Editor", selection: $editorBundleID) {
                    ForEach(EditorChoice.allCases.filter { OpenActions.installed($0.rawValue) }) {
                        Text($0.name).tag($0.rawValue)
                    }
                }
                LabeledContent("GitHub CLI") {
                    Text(model.githubCLIAvailable ? "Found" : "Not installed")
                        .foregroundStyle(model.githubCLIAvailable ? Color.green : Color.secondary)
                }
            }

            Section("General") {
                Toggle("Open Lopper at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Show safe count in the menu bar", isOn: $showCountInMenuBar)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
    }

    private func commitProtected() {
        let patterns = protectedText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        model.updateSettings { $0.protectedPatterns = patterns }
        model.startScan()
    }
}
