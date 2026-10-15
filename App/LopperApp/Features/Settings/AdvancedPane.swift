import SwiftUI
import Lopper

struct AdvancedPane: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingReset = false

    var body: some View {
        PaneScaffold {
            Section {
                Button("Show settings file in Finder") { OpenActions.reveal(model.settingsFileURL) }
                Button("Show undo history in Finder") { OpenActions.reveal(UndoLog.defaultURL) }
            } header: {
                Text("Your data")
            } footer: {
                Text("Everything Lopper keeps is in two readable files. Nothing leaves this Mac.")
            }

            Section {
                Button("Reset all settings…", role: .destructive) { confirmingReset = true }
            } footer: {
                Text("Restores every setting to its default and returns to the folder chooser. The current file is kept next to it as a backup.")
            }
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmingReset) {
            Button("Reset settings", role: .destructive) { model.resetSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your removals and their undo history are not affected.")
        }
    }
}
