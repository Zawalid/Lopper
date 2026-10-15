import SwiftUI
import Lopper

struct SafetyPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneScaffold {
            Section {
                TagListEditor(
                    tags: Binding(
                        get: { model.settings.protectedPatterns },
                        set: { value in model.updateSettings { $0.protectedPatterns = value } }),
                    prompt: "main, release/*")
            } header: {
                Text("Protected branches")
            } footer: {
                Text("These are never offered for removal. Patterns can use * as a wildcard.")
            }

            Section {
                Stepper(
                    "Keep removals restorable for \(model.settings.trashRetentionDays) days",
                    value: Binding(
                        get: { model.settings.trashRetentionDays },
                        set: { value in model.updateSettings { $0.trashRetentionDays = value } }),
                    in: 1...365)
                Stepper(
                    "Call a branch stale after \(model.settings.staleDays) days",
                    value: Binding(
                        get: { model.settings.staleDays },
                        set: { value in model.updateSettings { $0.staleDays = value } }),
                    in: 1...730)
            }

            Section {
                TagListEditor(
                    tags: Binding(
                        get: { model.settings.disposableNames },
                        set: { value in model.updateSettings { $0.disposableNames = value } }),
                    prompt: "node_modules, .cache")
            } header: {
                Text("Throwaway files")
            } footer: {
                Text("Files and folders with these names do not count as unsaved work inside a worktree.")
            }

            Section {
                let overrides = model.settings.repos.sorted { $0.key < $1.key }
                if overrides.isEmpty {
                    Text("Settings you change for one repository appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(overrides, id: \.key) { path, value in
                    OverrideRow(path: path, overrides: value)
                }
            } header: {
                Text("Repositories with their own settings")
            }
        }
    }
}

private struct OverrideRow: View {
    let path: String
    let overrides: RepoOverrides
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset") { model.removeRepoOverrides(for: URL(fileURLWithPath: path)) }
                .controlSize(.small)
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let branch = overrides.defaultBranch { parts.append("default branch \(branch)") }
        if overrides.protectedPatterns != nil { parts.append("own protected branches") }
        if !overrides.disposableNames.isEmpty {
            parts.append(Plural.count(overrides.disposableNames.count, "throwaway name"))
        }
        if overrides.isIgnored { parts.append("hidden") }
        return parts.joined(separator: ", ")
    }
}
