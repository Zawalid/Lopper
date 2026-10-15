import SwiftUI

struct ToolsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneScaffold {
            Section {
                Picker("Editor", selection: Binding(
                    get: { model.preferences.editorBundleID },
                    set: { model.preferences.setEditorBundleID($0) }
                )) {
                    ForEach(EditorChoice.allCases.filter { OpenActions.installed($0.rawValue) }) {
                        Text($0.name).tag($0.rawValue)
                    }
                }
                Picker("Terminal", selection: Binding(
                    get: { model.preferences.terminalBundleID },
                    set: { model.preferences.setTerminalBundleID($0) }
                )) {
                    ForEach(TerminalChoice.allCases.filter { OpenActions.installed($0.rawValue) }) {
                        Text($0.name).tag($0.rawValue)
                    }
                }
            } footer: {
                Text("Used by \"Open in editor\" and \"Open in Terminal\" on a worktree.")
            }

            Section {
                LabeledContent("git") {
                    Text(model.toolStatus.gitVersion ?? "Not found")
                        .foregroundStyle(model.toolStatus.gitVersion == nil ? Color.orange : Color.secondary)
                }
                LabeledContent("GitHub CLI") {
                    switch model.toolStatus.gitHubCLI {
                    case .notInstalled:
                        Text("Not installed").foregroundStyle(.secondary)
                    case .installed(let version, _):
                        Text("Version \(version)").foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Check again") { Task { await model.refreshToolStatus() } }
                }
            } header: {
                Text("Command line tools")
            } footer: {
                if case .notInstalled = model.toolStatus.gitHubCLI {
                    Text("Without the GitHub CLI, branches merged through pull requests are only recognised when git itself can prove it.")
                }
            }
        }
        .task { await model.refreshToolStatus() }
    }
}
