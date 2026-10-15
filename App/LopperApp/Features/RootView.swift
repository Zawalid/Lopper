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
                    if model.route.hasInspector {
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
        .sheet(isPresented: $model.showsPalette) {
            CommandPaletteView()
        }
        .sheet(isPresented: Binding(
            get: { model.diskClear != nil },
            set: { if !$0 { model.dismissDiskClear() } }
        )) {
            DiskReviewSheet()
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
        .overlay(alignment: .bottom) {
            if let confirmation = model.confirmation {
                ConfirmationPill(message: confirmation)
                    .padding(.bottom, model.toast == nil ? 60 : 116)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toast)
        .animation(.snappy, value: model.confirmation)
    }
}

private struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        content
            // Fill the column first, then paint it: an empty state hugs its text, and a background applied to
            // that would only cover a rectangle around it.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.pageBackground)
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
        case .agents: AgentsView()
        case .disk: DiskView()
        case .history: HistoryView()
        case .repo(let id): RepoWorkbenchView(repoID: id)
        }
    }
}
