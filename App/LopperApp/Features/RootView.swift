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
        .frame(minWidth: 1040, minHeight: 520)
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

/// Scan progress as a quiet caption and a thin bar at the bottom of the sidebar. It used to be a toolbar item,
/// which macOS draws as its own glass bubble next to the title and which pushed the title around.
private struct ScanStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if case .scanning(let done, let total) = model.phase {
            VStack(alignment: .leading, spacing: 4) {
                Text(total > 0 ? "Scanning \(done) of \(total)" : "Looking for repositories…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        content
            // The notice lives in the detail column only. An inset on the whole split view would also push
            // the sidebar's first row up under the traffic lights.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let notice = model.notice {
                    Banner(
                        symbol: "exclamationmark.triangle", message: notice,
                        onDismiss: { model.dismissNotice() })
                    .padding(Theme.Spacing.md)
                }
            }
    }

    @ViewBuilder private var content: some View {
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
        // The footer is a sibling of the list, not an inset over it: on a sidebar-style list an inset does not
        // move the scroll content, so the last repository ended up underneath "Add folder".
        VStack(spacing: 0) {
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

            ScanStatus()
            Divider()
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
