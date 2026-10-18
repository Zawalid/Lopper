import SwiftUI
import ServiceManagement

struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @Environment(AppUpdater.self) private var updater: AppUpdater?
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

            if let updater {
                Section {
                    Toggle("Check for updates automatically", isOn: Binding(
                        get: { updater.automaticallyChecks },
                        set: { updater.automaticallyChecks = $0 }
                    ))
                    .help("Off by default. When on, Lopper asks GitHub once a day if a newer version exists.")
                    Button("Check for Updates…") { updater.checkNow() }
                        .buttonStyle(.lopperSecondary)
                        .disabled(!updater.canCheck)
                        .help("Ask GitHub now if a newer version exists. Nothing is installed until you say so.")
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Lopper itself makes no other network calls. It asks GitHub for one small file, so GitHub sees the request like any download. It shows you what is new and installs nothing until you press Install Update. Homebrew users can also run brew upgrade.")
                }
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
