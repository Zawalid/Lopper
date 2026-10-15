import SwiftUI

/// The Settings window: one tab per pane from `SettingsPane.available`, one file per pane.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SettingsPane

    init(initialPane: SettingsPane = .general) {
        _selection = State(initialValue: initialPane)
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(SettingsPane.available) { pane in
                content(for: pane)
                    .tabItem { Label(pane.title, systemImage: pane.symbol) }
                    .tag(pane)
            }
        }
        .frame(width: 580, height: 480)
        .onAppear { applyRequestedPane() }
        .onChange(of: model.requestedSettingsPane) { applyRequestedPane() }
    }

    private func applyRequestedPane() {
        if let pane = model.takeRequestedSettingsPane() { selection = pane }
    }

    @ViewBuilder
    private func content(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralPane()
        case .folders: FoldersPane()
        case .safety: SafetyPane()
        case .tools: ToolsPane()
        case .advanced: AdvancedPane()
        case .about: AboutPane()
        case .notifications: EmptyView()
        }
    }
}
