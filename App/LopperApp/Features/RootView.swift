import SwiftUI
import AppKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.settings.roots.isEmpty {
                OnboardingView()
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
                } detail: {
                    DetailView()
                }
                .toolbar {
                    ToolbarItem(placement: .navigation) { ScanStatus() }
                    ToolbarItem {
                        Button { model.startScan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                            .help("Rescan (Command-R)")
                            .disabled(model.isScanning || model.isCleaning)
                    }
                    if case .repo = model.route {
                        ToolbarItem {
                            Button { model.showInspector.toggle() } label: {
                                Label("Inspector", systemImage: "sidebar.right")
                            }
                            .help("Show or hide the inspector (Command-I)")
                        }
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let notice = model.notice {
                Banner(
                    symbol: "exclamationmark.triangle", message: notice,
                    onDismiss: { model.dismissNotice() })
                .padding(Theme.Spacing.md)
            }
        }
        .task { model.startScan() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.scanIfStale()
        }
        .sheet(isPresented: Binding(
            get: { model.clean != nil },
            set: { if !$0 { model.dismissClean() } }
        )) {
            CleanSheet()
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                UndoToastView(
                    toast: toast,
                    onUndo: { model.undoToast() },
                    onDismiss: { model.dismissToast() })
                .padding(.bottom, 60)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(12))
                    model.dismissToast()
                }
            }
        }
        .animation(.snappy, value: model.toast)
    }
}

private struct ScanStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .scanning(let done, let total):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(total > 0 ? "Scanning \(done) of \(total)" : "Scanning…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        default:
            EmptyView()
        }
    }
}

private struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.route {
        case .overview: OverviewView()
        case .history: HistoryView()
        case .repo(let id): RepoWorkbenchView(repoID: id)
        }
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: Binding<Route?>(
            get: { model.route },
            set: { if let route = $0 { model.route = route } }
        )) {
            Section {
                Label("Overview", systemImage: "square.grid.2x2").tag(Route.overview)
                Label("History", systemImage: "clock.arrow.circlepath").tag(Route.history)
            }
            Section("Repositories") {
                ForEach(model.orderedSummaries) { summary in
                    HStack {
                        Label(summary.name, systemImage: summary.failure == nil ? "shippingbox" : "exclamationmark.triangle")
                        Spacer()
                        if summary.safe > 0 {
                            Text("\(summary.safe)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(Route.repo(summary.id))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    FolderPicker.choose { model.addRoots($0) }
                } label: {
                    Label("Add folder", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .help("Add a folder to scan (Command-O)")
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Settings (Command-comma)")
                .accessibilityLabel("Settings")
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
        }
    }
}
