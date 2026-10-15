import SwiftUI
import ServiceManagement

struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        let preferences = model.preferences
        PaneScaffold {
            Section {
                Picker("Appearance", selection: Binding(
                    get: { preferences.appearance },
                    set: { preferences.setAppearance($0) }
                )) {
                    ForEach(AppPreferences.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Open Lopper at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Show Lopper in the Dock", isOn: Binding(
                    get: { preferences.showInDock },
                    set: { preferences.setShowInDock($0) }
                ))
                Toggle("Show the safe count in the menu bar", isOn: Binding(
                    get: { preferences.showCountInMenuBar },
                    set: { preferences.setShowCountInMenuBar($0) }
                ))
            } footer: {
                Text("Without a Dock icon, Lopper lives in the menu bar and opens its window from there.")
            }

            Section {
                Toggle("Tell me once a week what can be cleaned up", isOn: Binding(
                    get: { preferences.weeklyDigest },
                    set: { model.setWeeklyDigest($0) }
                ))
            } footer: {
                Text("One notification, at most weekly, and only when at least 1 GB can be given back.")
            }
        }
    }
}
