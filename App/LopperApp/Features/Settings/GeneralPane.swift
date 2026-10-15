import SwiftUI
import ServiceManagement

struct GeneralPane: View {
    @AppStorage("showCountInMenuBar") private var showCountInMenuBar = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        PaneScaffold {
            Section {
                Toggle("Open Lopper at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Toggle("Show the safe count in the menu bar", isOn: $showCountInMenuBar)
            } footer: {
                Text("Lopper lives in the menu bar so you can see what is ready to clean without opening a window.")
            }
        }
    }
}
