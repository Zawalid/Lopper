import SwiftUI

@main
struct LopperApp: App {
    @State private var model = AppModel(client: LiveEngineClient())

    var body: some Scene {
        Window("Lopper", id: "main") {
            RootView()
                .environment(model)
        }
        .defaultSize(width: 1080, height: 700)
        .commands { LopperCommands(model: model) }

        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)

        SwiftUI.Settings {
            SettingsView().environment(model)
        }
    }
}

struct LopperCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Rescan") { model.startScan() }
                .keyboardShortcut("r")
            Button("Select All Safe Items") { model.checkAllSafe() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Review and Clean Selection") { model.beginCleanChecked() }
                .keyboardShortcut(.delete, modifiers: .command)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo Last Clean") { model.undoToast() }
                .keyboardShortcut("z")
                .disabled(model.toast == nil)
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") { model.showInspector.toggle() }
                .keyboardShortcut("i")
            Button("Overview") { model.route = .overview }
                .keyboardShortcut("1")
            Button("History") { model.route = .history }
                .keyboardShortcut("2")
        }
    }
}
