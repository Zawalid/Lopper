import AppKit
import SwiftUI

@main
struct LopperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel = {
        let model = AppModel(client: LiveEngineClient(), preferences: .standard)
        model.digest = SystemDigestNotifier()
        return model
    }()

    var body: some Scene {
        Window("Lopper", id: "main") {
            RootView()
                .environment(model)
                #if DEBUG
                .task { await ScreenshotMode.runIfRequested(model: model) }
                #endif
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
        CommandGroup(after: .textEditing) {
            Button("Command Palette…") { model.showsPalette = true }
                .keyboardShortcut("k")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo Last Clean") { model.undoToast() }
                .keyboardShortcut("z")
                .disabled(model.toast == nil)
        }
        CommandMenu("Item") {
            Button("Next Item") { model.focusNextRow() }
                .keyboardShortcut("]")
                .disabled(model.triagePosition?.nextID == nil)
            Button("Previous Item") { model.focusPreviousRow() }
                .keyboardShortcut("[")
                .disabled(model.triagePosition?.previousID == nil)
            Divider()
            if let row = model.focusedRow {
                let kept = model.isKeptBranch(row.title, in: row.repoRoot)
                Button(kept ? "Stop Keeping Branch" : "Keep Branch") {
                    if kept {
                        model.stopKeepingBranch(row.title, in: row.repoRoot)
                    } else {
                        model.keepBranch(row.title, in: row.repoRoot)
                    }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(row.verdict == .protected && !kept)

                Button(model.isSnoozed(row) ? "Wake Item" : "Snooze for a Week") {
                    if model.isSnoozed(row) {
                        model.wake(row)
                    } else {
                        model.snooze(row, for: .oneWeek)
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(row.verdict == .protected)

                Button("Copy Branch Name") { model.copy(row.title, confirming: "Copied branch name") }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Review and Clean Item") { model.beginClean(rows: [row]) }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(!row.isSelectable || model.isCleaning || model.isScanning)
            } else {
                Text("Select an item to see its actions")
            }
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

