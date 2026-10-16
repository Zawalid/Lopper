import SwiftUI
import AppKit
import Lopper

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
        VStack(alignment: .leading, spacing: 0) {
            switch model.overviewState {
            case .scanning, .needsFolders, .nothingFound, .allTidy:
                header(title: stateTitle, subtitle: stateSubtitle)
            case .ready:
                readyBody
            }
            footer
        }
        .frame(width: 320)
    }

    // MARK: States

    private var readyBody: some View {
        let totals = model.totals
        return VStack(alignment: .leading, spacing: 0) {
            header(title: model.heroValue, subtitle: model.heroHeadline.lowercased())
            if let space = model.volumeSpace {
                VolumeStrip(space: space, reclaimable: totals.reclaimableBytes + model.diskTotals.clearableBytes)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.bottom, Theme.Spacing.md)
            }
            VStack(spacing: 0) {
                MenuRow(
                    symbol: "arrow.triangle.branch", title: "Branches and worktrees",
                    detail: "\(Plural.count(totals.safeBranches, "branch", "branches")), \(Plural.count(totals.safeWorktrees, "worktree"))",
                    value: "\(totals.safe) safe", tint: Color.accentColor
                ) { open(.overview) }
                if let line = Self.agentsLine(for: model.agentsSummary) {
                    MenuRow(
                        symbol: "sparkles", title: "Agents", detail: line,
                        value: SizeFormat.string(model.agentsSummary.reclaimableBytes), tint: Color.accentColor
                    ) { open(.agents) }
                }
                let folders = model.diskTotals.clearableBytes
                if folders > 0 {
                    MenuRow(
                        symbol: "shippingbox", title: "Generated folders",
                        detail: Plural.count(model.diskTotals.folders, "folder") + " you can rebuild",
                        value: SizeFormat.string(folders), tint: Color.accentColor
                    ) { open(.disk) }
                }
                if model.localOnlySummary.items > 0 {
                    MenuRow(
                        symbol: "icloud.slash", title: "Only on this Mac",
                        detail: "Not pushed or committed", value: "\(model.localOnlySummary.items)", tint: Color.secondary
                    ) { open(.onlyHere) }
                }
                if totals.review > 0 {
                    MenuRow(
                        symbol: "eye", title: "Need a look", detail: "Not confirmed as merged",
                        value: "\(totals.review)", tint: VerdictKind.review.tint
                    ) { open(.overview) }
                }
            }
            Button {
                openMain()
                model.beginCleanAllSafe()
            } label: {
                Text("Review and clean").frame(maxWidth: .infinity)
            }
            .buttonStyle(.lopperPrimary)
            .controlSize(.large)
            .padding(Theme.Spacing.lg)
        }
    }

    private func header(title: String, subtitle: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Spacing.md)
            VStack(alignment: .trailing, spacing: 2) {
                Button { model.startScan() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.lopperIcon)
                .help("Rescan")
                .accessibilityLabel("Rescan")
                Text(lastScanText).font(.caption2).foregroundStyle(Theme.metaText)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.md)
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.sm) {
            FooterButton(title: "Open Lopper", emphasized: true) { openMain() }
            Spacer()
            FooterButton(title: "Quit", shortcut: "\u{2318}Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.sm)
        .overlay(alignment: .top) { Divider() }
    }

    private var stateTitle: String {
        switch model.overviewState {
        case .scanning: "Scanning"
        case .needsFolders: "Choose folders"
        case .nothingFound: "Nothing found"
        case .allTidy, .ready: "All tidy"
        }
    }

    private var stateSubtitle: String {
        switch model.overviewState {
        case .scanning: "Looking through your folders"
        case .needsFolders: "Tell Lopper where your projects live"
        case .nothingFound: "No repositories in your folders"
        case .allTidy, .ready: "Nothing to remove right now"
        }
    }

    private func open(_ route: Route) {
        openMain()
        model.route = route
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

/// One thing Lopper found, as a full-width row that highlights under the pointer like a native menu item.
private struct MenuRow: View {
    let symbol: String
    let title: String
    let detail: String
    let value: String
    let tint: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: Theme.Spacing.sm)
                Text(value).font(.data(.callout, weight: .medium)).monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(height: 46)
            .background(Color.primary.opacity(isHovering ? 0.07 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerCursor()
        .accessibilityElement(children: .combine)
    }
}

/// How full the disk is, with the part Lopper could give back marked at the end of the used space.
private struct VolumeStrip: View {
    let space: VolumeSpace
    let reclaimable: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                let total = Double(max(space.total, 1))
                let usedWidth = proxy.size.width * Double(space.used) / total
                let reclaimWidth = min(usedWidth, proxy.size.width * Double(reclaimable) / total)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(Color.secondary.opacity(0.5)).frame(width: max(4, usedWidth))
                    if reclaimWidth > 1 {
                        Capsule().fill(Color.accentColor)
                            .frame(width: max(4, reclaimWidth))
                            .offset(x: max(0, usedWidth - reclaimWidth))
                    }
                }
            }
            .frame(height: 6)
            Text("\(SizeFormat.string(space.available)) free of \(SizeFormat.string(space.total))")
                .font(.caption2).foregroundStyle(Theme.metaText)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A footer action with a visible hover and press state, a pointing-hand cursor and a keyboard focus ring.
private struct FooterButton: View {
    let title: String
    var shortcut: String?
    var emphasized = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let shortcut {
                    Text(shortcut).font(.caption).foregroundStyle(.tertiary)
                }
            }
            .font(.callout.weight(emphasized ? .medium : .regular))
            .foregroundStyle(emphasized ? Theme.accentText : (isHovering ? Color.primary : Color.secondary))
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: 28)
            .background(Color.primary.opacity(isHovering ? 0.09 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(FooterPressStyle())
        .onHover { isHovering = $0 }
        .pointerCursor()
    }
}

private struct FooterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
