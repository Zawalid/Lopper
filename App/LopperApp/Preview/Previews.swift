#if DEBUG
import SwiftUI
import Lopper

// Every screen with sample data, for Xcode's canvas (Option-Command-Return) and for quick visual checks.
// Edit a view, save, and the matching preview below re-renders. Sample data lives in Fixtures.swift.

// MARK: Screens

#Preview("Overview, ready") {
    OverviewView()
        .environment(AppModel.preview(snapshots: [Fixtures.sample, secondRepo]))
        .frame(width: 900, height: 620)
}

#Preview("Overview, only branches are safe") {
    OverviewView()
        .environment(AppModel.preview(snapshots: [branchesOnly], sizes: [:]))
        .frame(width: 900, height: 560)
}

#Preview("Overview, all tidy") {
    OverviewView()
        .environment(AppModel.preview(snapshots: [Fixtures.snapshot(branches: [Fixtures.branch("main", .protected)])]))
        .frame(width: 900, height: 520)
}

#Preview("Overview, scanning") {
    OverviewView()
        .environment(AppModel.preview(snapshots: [], phase: .scanning(done: 3, total: 20)))
        .frame(width: 900, height: 420)
}

#Preview("Overview, nothing found") {
    OverviewView()
        .environment(AppModel.preview(snapshots: []))
        .frame(width: 900, height: 420)
}

#Preview("Overview, a repository failed") {
    OverviewView()
        .environment(AppModel.preview(failures: [URL(fileURLWithPath: "/code/broken")]))
        .frame(width: 900, height: 620)
}

#Preview("Onboarding") {
    OnboardingView()
        .environment(AppModel.preview(snapshots: [], roots: []))
        .frame(width: 720, height: 520)
}

#Preview("Repository workbench") {
    RepoWorkbenchView(repoID: Fixtures.root.path)
        .environment(AppModel.preview(focusedRowID: "worktree:/code/wt/feat/in-worktree"))
        .frame(width: 1000, height: 560)
}

#Preview("Inspector, safe worktree") {
    InspectorView()
        .environment(AppModel.preview(focusedRowID: "worktree:/code/wt/feat/in-worktree"))
        .frame(width: 320, height: 520)
}

#Preview("Inspector, review branch") {
    InspectorView()
        .environment(AppModel.preview(focusedRowID: "branch:/code/api#wip/unmerged"))
        .frame(width: 320, height: 420)
}

#Preview("Inspector, nothing selected") {
    InspectorView()
        .environment(AppModel.preview())
        .frame(width: 320, height: 320)
}

#Preview("Clean sheet, review") {
    let model = AppModel.preview()
    model.beginCleanAllSafe()
    return CleanSheet().environment(model)
}

#Preview("History") {
    HistoryView()
        .environment(AppModel.preview(history: Fixtures.historyRecords, route: .history))
        .frame(width: 720, height: 460)
}

#Preview("History, empty") {
    HistoryView()
        .environment(AppModel.preview(route: .history))
        .frame(width: 720, height: 360)
}

#Preview("Menu bar popover") {
    MenuBarView()
        .environment(AppModel.preview())
}

#Preview("Settings") {
    SettingsView()
        .environment(AppModel.preview())
}

#Preview("Whole window") {
    RootView()
        .environment(AppModel.preview(snapshots: [Fixtures.sample, secondRepo]))
        .frame(width: 1080, height: 700)
}

// MARK: Design system gallery

#Preview("Design system") {
    VStack(alignment: .leading, spacing: 20) {
        HStack { VerdictChip(kind: .safe); VerdictChip(kind: .review); VerdictChip(kind: .protected) }
        HealthBar(safe: 12, review: 3, protected: 5).frame(width: 260)
        RepoCard(
            summary: RepoSummary(
                id: "/code/api", name: "api", root: Fixtures.root, safeBranches: 8, safeWorktrees: 2,
                review: 1, protected: 3, reclaimableBytes: 1_240_000_000, defaultBranch: "main", failure: nil),
            action: {})
            .frame(width: 280)
        Banner(
            symbol: "link", message: "Install the GitHub CLI to detect branches merged through pull requests.",
            actionTitle: "Learn more", action: {}, onDismiss: {})
        UndoToastView(toast: UndoToast(id: UUID(), removed: 12, reclaimed: 1_240_000_000), onUndo: {}, onDismiss: {})
        EmptyState(symbol: "checkmark.seal", title: "All tidy", message: "Nothing is waiting to be cleaned up.")
    }
    .padding(24)
    .frame(width: 560)
}

// MARK: Sample data used only by previews

private let secondRepo: RepoSnapshot = {
    let root = URL(fileURLWithPath: "/code/apps")
    return Fixtures.snapshot(
        name: "apps", root: root,
        branches: [
            Fixtures.branch("main", .protected, root: root),
            Fixtures.branch("feat/ui", .safe, root: root, ageDays: 33),
            Fixtures.branch("fix/layout", .review, root: root, ageDays: 4),
        ])
}()

private let branchesOnly: RepoSnapshot = Fixtures.snapshot(branches: [
    Fixtures.branch("main", .protected),
    Fixtures.branch("feat/a", .safe, ageDays: 45),
    Fixtures.branch("feat/b", .safe, ageDays: 12),
])
#endif
