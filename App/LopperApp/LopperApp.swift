import AppKit
import SwiftUI

@main
struct LopperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel(client: LiveEngineClient(), preferences: .standard)

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
            Button("Add Folder…") { FolderPicker.choose { model.addRoots($0) } }
                .keyboardShortcut("o")
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
            ForEach(PrimaryRoute.allCases) { item in
                Button(item.title) { model.route = item.route }
                    .keyboardShortcut(KeyEquivalent(item.shortcutDigit))
            }
        }
    }
}

/// Applies appearance and Dock presence before the first window appears.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        WindowLayoutDefaults.discardSavedSplitViewFrames()
        MainActor.assumeIsolated { AppPreferences.standard.applyAtLaunch() }
    }
}

