import SwiftUI
import AppKit

enum FolderPicker {
    @MainActor
    static func choose(_ completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = "Choose the folders that contain your projects."
        if panel.runModal() == .OK { completion(panel.urls) }
    }

    /// Common project folders that exist on this machine, offered as one-click suggestions.
    static var suggestions: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Developer", "Projects", "Code", "Documents/GitHub", "Sites"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "scissors")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Clear out your old branches and worktrees")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Lopper finds the branches and worktrees you no longer need, shows why each one is safe to remove, and lets you undo any removal.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if !FolderPicker.suggestions.isEmpty {
                VStack(spacing: Theme.Spacing.sm) {
                    Text("Found on this Mac").font(.caption).foregroundStyle(.secondary)
                    ForEach(FolderPicker.suggestions, id: \.self) { url in
                        Button {
                            model.setRoots([url])
                        } label: {
                            Label(abbreviated(url), systemImage: "folder")
                                .frame(maxWidth: 260, alignment: .leading)
                        }
                        .buttonStyle(.lopperSecondary)
                        .controlSize(.large)
                    }
                }
                .padding(.top, Theme.Spacing.sm)
            }

            Button("Choose folders…") {
                FolderPicker.choose { model.setRoots($0) }
            }
            .buttonStyle(.lopperPrimary)
            .controlSize(.large)
            .padding(.top, Theme.Spacing.sm)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
