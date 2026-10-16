import SwiftUI
import AppKit

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "scissors")
            if model.preferences.showCountInMenuBar, model.totals.safe > 0 {
                Text("\(model.totals.safe)").monospacedDigit()
            }
        }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let totals = model.totals
        VStack(spacing: Theme.Spacing.md) {
            switch model.overviewState {
            case .scanning, .needsFolders:
                ProgressView().controlSize(.small)
                Text(model.overviewState == .needsFolders ? "Choose folders in Lopper" : "Scanning…")
                    .foregroundStyle(.secondary)
            case .nothingFound:
                Image(systemName: "magnifyingglass").font(.title).foregroundStyle(.secondary)
                Text("No repositories found").font(.headline)
            case .allTidy:
                Image(systemName: "checkmark.seal").font(.title).foregroundStyle(.secondary)
                Text("All tidy").font(.headline)
            case .ready:
                Text(model.heroHeadline).font(.caption).foregroundStyle(.secondary)
                Text(model.heroValue)
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
                Text("\(Plural.count(totals.safeBranches, "branch", "branches")) and \(Plural.count(totals.safeWorktrees, "worktree")) are safe to remove")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let line = Self.agentsLine(for: model.agentsSummary) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(line).font(.callout).foregroundStyle(.secondary)
                        Button("Review agents") {
                            openMain()
                            model.route = .agents
                        }
                        .buttonStyle(.link)
                    }
                }
                let folders = model.diskTotals.clearableBytes
                if folders > 0 {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text("\(SizeFormat.string(folders)) in generated folders")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Open Disk") {
                            openMain()
                            model.route = .disk
                        }
                        .buttonStyle(.link)
                    }
                }
                Button("Review and clean") {
                    openMain()
                    model.beginCleanAllSafe()
                }
                .buttonStyle(.lopperPrimary)
                .controlSize(.large)
            }
            Divider()
            HStack {
                Text(lastScanText).font(.caption).foregroundStyle(Theme.metaText)
                Spacer()
                Button { model.startScan() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.lopperIcon)
                    .help("Rescan")
                    .accessibilityLabel("Rescan")
                Button("Open Lopper") { openMain() }.buttonStyle(.lopperLink)
            }
            Button("Quit Lopper") { NSApp.terminate(nil) }
                .buttonStyle(.lopperSecondary)
                .controlSize(.small)
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 300)
    }

    /// "3 agent worktrees finished" or nil when there are none to reclaim.
    static func agentsLine(for summary: AgentsSummary) -> String? {
        summary.reclaimable > 0
            ? "\(Plural.count(summary.reclaimable, "agent worktree")) finished"
            : nil
    }

    private var lastScanText: String {
        guard let date = model.lastScan else { return model.isScanning ? "Scanning…" : "Not scanned yet" }
        return "Scanned " + date.formatted(.relative(presentation: .named))
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
