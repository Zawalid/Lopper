import AppKit
import Foundation
import Observation
import Lopper

enum Route: Hashable {
    case overview
    case agents
    case disk
    case onlyHere
    case history
    case repo(String)

    /// Pages that show a details column beside the table.
    var hasInspector: Bool {
        switch self {
        case .repo, .agents, .history: true
        case .overview, .disk, .onlyHere: false
        }
    }
}

enum ScanPhase: Equatable {
    case idle
    case scanning(done: Int, total: Int)
    case ready(Date)
}

enum VerdictFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case safe = "Safe"
    case review = "Review"
    case protected = "Protected"

    var id: String { rawValue }

    func matches(_ kind: VerdictKind) -> Bool {
        switch self {
        case .all: true
        case .safe: kind == .safe
        case .review: kind == .review
        case .protected: kind == .protected
        }
    }
}

enum KindFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case branches = "Branches"
    case worktrees = "Worktrees"

    var id: String { rawValue }

    func matches(_ kind: CleanupRow.Kind) -> Bool {
        switch self {
        case .all: true
        case .branches: kind == .branch
        case .worktrees: kind == .worktree
        }
    }
}

struct ItemOutcome: Identifiable, Equatable {
    enum Status: Equatable { case removed, skipped, failed }
    let id: String
    let title: String
    let status: Status
    let message: String?
}

struct CleanState: Equatable {
    enum Phase: Equatable {
        case review
        case running(done: Int, total: Int)
        case finished
    }

    var rows: [CleanupRow]
    var excluded: Set<String> = []
    var phase: Phase = .review
    var outcomes: [ItemOutcome] = []
    /// Selected rows that were removed. Not the git steps: a worktree and its branch are two steps and one row.
    var removedRows = 0
    var reclaimedBytes: Int64 = 0
    var batchID: UUID?

    /// The user pressed Stop: the item in flight finishes, then the batch ends.
    var isStopping = false

    var includedRows: [CleanupRow] { rows.filter { !excluded.contains($0.id) } }
    var includedBytes: Int64 { includedRows.reduce(0) { $0 + ($1.size ?? 0) } }
    var removedCount: Int { removedRows }
    var problemCount: Int { outcomes.filter { $0.status != .removed }.count }
}

struct UndoToast: Equatable, Identifiable {
    let id: UUID
    let removed: Int
    let reclaimed: Int64
    /// Generated folders sent to the Trash rather than branches and worktrees removed.
    var folders = false
}

/// What blocks the whole app, as opposed to a notice about one folder.
enum SetupIssue: Equatable {
    case gitMissing
    case foldersUnreadable
}

enum OverviewState: Equatable {
    case needsFolders
    case scanning(done: Int, total: Int)
    case nothingFound
    case allTidy(review: Int)
    case ready
}

struct Totals: Equatable {
    var repositories = 0
    var safeBranches = 0
    var safeWorktrees = 0
    var review = 0
    var protected = 0
    var reclaimableBytes: Int64 = 0

    var safe: Int { safeBranches + safeWorktrees }
}

@MainActor
@Observable
final class AppModel {
    let client: any EngineClient
    let preferences: AppPreferences
    private let store: SettingsStore

    private(set) var settings: Settings { didSet { invalidateRows() } }
    private(set) var phase: ScanPhase = .idle
    private(set) var results: [RepoScanResult] = [] { didSet { invalidateRows() } }
    private(set) var sizes: [String: DiskUsage] = [:] { didSet { invalidateRows() } }
    /// Worktrees measured since the latest scan finished. Only these have trustworthy activity times.
    private(set) var measuredPaths: Set<String> = [] { didSet { invalidateRows() } }
    var history: [UndoRecord] = []
    /// Folders Lopper cleared that are still in the Trash, so still using disk.
    var trashedFolders: [UndoRecord] = []

    /// The current page. Backed by stored state so views are notified, and written to preferences so the app
    /// reopens on the same page.
    var route: Route {
        get { routeStorage }
        set {
            routeStorage = newValue
            preferences.setLastRoute(newValue)
        }
    }

    var showInspector: Bool {
        get { inspectorStorage }
        set {
            inspectorStorage = newValue
            preferences.setInspectorVisible(newValue)
        }
    }

    private var routeStorage: Route = .overview
    private var inspectorStorage = true
    var checked: Set<String> = []
    var focusedRowID: String?
    var verdictFilter: VerdictFilter = .all
    var kindFilter: KindFilter = .all
    var searchText = ""
    var agentFilter: AgentStateFilter = .all
    var agentToolFilter: AgentTool?
    var agentSearchText = ""
    /// Finished rows the user unticked on the Agents page.
    var agentExcluded: Set<String> = []
    var clean: CleanState?
    var toast: UndoToast?

    // Disk page
    var artifacts: [DiskArtifact] = []
    var artifactPhase: ArtifactScanPhase = .idle
    var developerCaches: [DiskArtifact] = []
    var volumeSpace: VolumeSpace?
    var diskGrouping: DiskGrouping = .project
    var diskUntouchedOnly = false
    var diskSearchText = ""
    var diskFocusedID: String?
    var diskClear: DiskClearState?
    var showsPalette = false
    /// The setup flow is on screen. It stays up after the folders are saved so the first scan can be watched,
    /// and ends only when the person opens the app.
    private(set) var isOnboarding: Bool
    /// Tells the person what could be cleaned up. Replaced by a silent one in tests and previews.
    var digest: any DigestNotifying = SilentDigestNotifier()

    /// A short message about something that did not work (for example a restore that was blocked).
    var notice: String?

    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?
    private var cleanControl = BatchControl()
    private var lastCompletedScan: Date?
    let clock: @Sendable () -> Date

    init(
        client: any EngineClient,
        store: SettingsStore = .standard,
        settings: Settings? = nil,
        preferences: AppPreferences = AppPreferences(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clock = now
        self.client = client
        self.store = store
        self.preferences = preferences
        self.routeStorage = preferences.lastRoute
        self.isOnboarding = false
        self.inspectorStorage = preferences.inspectorVisible
        if let settings {
            self.settings = settings
        } else {
            let loaded = store.load()
            self.settings = loaded.settings
            self.notice = Self.notice(for: loaded.outcome)
            switch loaded.outcome {
            case .unreadable, .recoveredFromCorruption: self.settingsNeedAttention = true
            default: break
            }
        }
        isOnboarding = self.settings.roots.isEmpty
        // A pending debounced save must not be lost when the app quits.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [store] _ in store.flush() }
    }

    private static func notice(for outcome: SettingsLoadOutcome) -> String? {
        switch outcome {
        case .created, .loaded, .migrated:
            return nil
        case .recoveredFromCorruption(let backup):
            return "Your settings file couldn't be read, so Lopper started with defaults. "
                + "The original was kept as \(backup.lastPathComponent)."
        case .unreadable:
            return "Your settings file exists but could not be read, so Lopper is using defaults and will not save "
                + "changes over it. Nothing is removed until it can be read."
        case .newerVersion(let backup):
            return "Your settings were saved by a newer version of Lopper. They are used as they are, and "
                + "a copy was kept as \(backup.lastPathComponent). This version will not change that file; update Lopper to edit it."
        }
    }

    var githubCLIAvailable: Bool { client.githubCLIAvailable }
    var isScanning: Bool { if case .scanning = phase { true } else { false } }
    var isCleaning: Bool { if case .running = clean?.phase { true } else { false } }
    var lastScan: Date? { if case .ready(let date) = phase { date } else { nil } }

    // MARK: Derived data

    var snapshots: [RepoSnapshot] {
        results.compactMap { if case .snapshot(let snapshot) = $0 { snapshot } else { nil } }
    }

    var allRows: [CleanupRow] {
        snapshots.flatMap { mappedRows($0) }
    }

    /// The rows of each repository, kept until what they are built from changes. Every redraw reads the totals and the
    /// summaries, and rebuilding eight thousand rows for each read made the window stutter on a large scan. They are
    /// also dropped after thirty seconds, because an agent worktree's state depends on the clock.
    @ObservationIgnored private var rowCache: [String: (rows: [CleanupRow], at: Date)] = [:]

    private func invalidateRows() { rowCache.removeAll(keepingCapacity: true) }

    private func mappedRows(_ snapshot: RepoSnapshot) -> [CleanupRow] {
        let now = clock()
        if let hit = rowCache[snapshot.repo.id], now.timeIntervalSince(hit.at) >= 0, now.timeIntervalSince(hit.at) < 30 {
            return hit.rows
        }
        let rows = RowMapper.rows(
            for: snapshot, sizes: sizes, policy: agentPolicy, now: now, measuredPaths: measuredPaths)
        rowCache[snapshot.repo.id] = (rows, now)
        return rows
    }

    func rows(forRepo id: String) -> [CleanupRow] {
        guard let snapshot = snapshots.first(where: { $0.repo.id == id }) else { return [] }
        return mappedRows(snapshot)
    }

    /// Rows of one repository after the search text and both filters are applied.
    func visibleRows(forRepo id: String) -> [CleanupRow] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return rows(forRepo: id).filter { row in
            verdictFilter.matches(row.verdict)
                && kindFilter.matches(row.kind)
                && (needle.isEmpty
                    || row.title.lowercased().contains(needle)
                    || row.location.lowercased().contains(needle))
        }
    }

    var summaries: [RepoSummary] {
        results.map { result in
            switch result {
            case .failure(let root, let message):
                return RepoSummary(
                    id: root.path, name: root.lastPathComponent, root: root, safeBranches: 0,
                    safeWorktrees: 0, review: 0, protected: 0, reclaimableBytes: 0,
                    defaultBranch: nil, failure: message)
            case .snapshot(let snapshot):
                let rows = mappedRows(snapshot)
                let safe = rows.filter(\.isBulkEligible)
                return RepoSummary(
                    id: snapshot.repo.id, name: snapshot.repo.name, root: snapshot.repo.root,
                    safeBranches: safe.filter { $0.kind == .branch }.count,
                    safeWorktrees: safe.filter { $0.kind == .worktree }.count,
                    review: rows.filter { $0.verdict == .review }.count,
                    protected: rows.filter { $0.verdict == .protected }.count,
                    reclaimableBytes: safe.reduce(0) { $0 + ($1.size ?? 0) },
                    defaultBranch: snapshot.repo.defaultBranch, failure: nil)
            }
        }
    }

    /// Repositories with something to do, most safe items first; failed scans are included so they are seen.
    var attentionSummaries: [RepoSummary] {
        summaries.filter(\.needsAttention).sorted(by: RepoSummary.attentionBefore)
    }

    var tidySummaries: [RepoSummary] {
        summaries
            .filter { !$0.needsAttention }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var orderedSummaries: [RepoSummary] { attentionSummaries + tidySummaries }

    var totals: Totals {
        summaries.reduce(into: Totals()) { totals, summary in
            totals.repositories += 1
            totals.safeBranches += summary.safeBranches
            totals.safeWorktrees += summary.safeWorktrees
            totals.review += summary.review
            totals.protected += summary.protected
            totals.reclaimableBytes += summary.reclaimableBytes
        }
    }

    var focusedRow: CleanupRow? {
        guard let focusedRowID else { return nil }
        return allRows.first { $0.id == focusedRowID }
    }

    var checkedRows: [CleanupRow] {
        allRows.filter { checked.contains($0.id) && $0.isSelectable }
    }

    var overviewState: OverviewState {
        if settings.roots.isEmpty { return .needsFolders }
        if results.isEmpty {
            switch phase {
            case .scanning(let done, let total): return .scanning(done: done, total: total)
            case .idle: return .scanning(done: 0, total: 0)
            case .ready: return .nothingFound
            }
        }
        let totals = self.totals
        return totals.safe == 0 ? .allTidy(review: totals.review) : .ready
    }

    /// With no measured size (only branches are safe) the hero shows how many items instead of "Zero KB".
    var heroHeadline: String {
        totals.reclaimableBytes > 0 ? "Ready to reclaim" : "Ready to clean"
    }

    var heroValue: String {
        let totals = self.totals
        return totals.reclaimableBytes > 0
            ? SizeFormat.string(totals.reclaimableBytes)
            : Plural.count(totals.safe, "item")
    }

    /// Worth telling someone only when a repository could have pull requests (it lives on GitHub) and the
    /// lookup failed. A repository with no remote, or one on another host, has nothing for `gh` to find.
    var prDetectionNote: Bool {
        snapshots.contains { snapshot in
            !snapshot.prDetectionAvailable && RemoteLinks.repository(remoteURL: snapshot.repo.remoteURL) != nil
        }
    }

    // MARK: Settings

    /// Applies a settings change, saves it (debounced), and rescans when the change affects what is found or
    /// how it is decided. Callers never start scans by hand for settings changes.
    /// True while the settings file could not be read in full. Defaults are in use, which can put the person's own
    /// protected branches back to the built-in ones, so nothing is removed until they have looked at it (changing a
    /// setting counts) or, for an unreadable file, until it can be read.
    private(set) var settingsNeedAttention = false

    static let settingsAttentionNotice = "Your settings could not be read in full, so Lopper is not removing anything yet. "
        + "Check Settings (changing any setting confirms them), or restore the original file."

    func updateSettings(_ change: (inout Settings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        // Changing a setting is the person confirming what is in use. An unreadable file stays blocked: nothing can be
        // saved over it, so there is nothing to confirm.
        if settingsNeedAttention, store.canWrite { settingsNeedAttention = false }
        let needsRescan = copy.requiresRescan(comparedTo: settings)
        settings = copy
        store.scheduleSave(copy)
        guard needsRescan else { return }
        if copy.roots.isEmpty {
            // Nothing left to look in: forget everything that came from the removed folders.
            scanTask?.cancel()
            results = []
            sizes = [:]
            measuredPaths = []
            checked = []
            focusedRowID = nil
            route = .overview
            phase = .idle
        } else {
            startScan()
        }
    }

    func completeOnboarding() { isOnboarding = false }

    func restartOnboarding() { isOnboarding = true }

    func setRoots(_ roots: [URL]) {
        updateSettings { $0.roots = roots }
    }

    /// Adds folders to the ones already being scanned (duplicates ignored) and rescans.
    func addRoots(_ urls: [URL]) {
        var seen = Set<String>()
        var merged: [URL] = []
        for url in settings.roots + urls where seen.insert(url.canonicalized.path).inserted {
            merged.append(url)
        }
        setRoots(merged.sorted { $0.path < $1.path })
    }

    func removeRoot(_ url: URL) {
        let key = url.canonicalized.path
        setRoots(settings.roots.filter { $0.canonicalized.path != key })
    }

    // MARK: Settings window support

    private(set) var toolStatus: ToolStatus = .unknown
    /// False until the first check finished, so a slow check is not mistaken for "git is missing".
    private(set) var toolStatusLoaded = false

    /// A pane another screen wants the Settings window to show. The window takes it when it appears or while
    /// it is open, so "Manage folders" lands on Folders instead of wherever Settings was left.
    private(set) var requestedSettingsPane: SettingsPane?

    func requestSettingsPane(_ pane: SettingsPane) { requestedSettingsPane = pane }

    func takeRequestedSettingsPane() -> SettingsPane? {
        defer { requestedSettingsPane = nil }
        return requestedSettingsPane
    }

    var settingsFileURL: URL { store.url }

    func refreshToolStatus() async {
        toolStatus = await client.toolStatus()
        toolStatusLoaded = true
        noteSetupIssue()
    }

    // MARK: Diagnostics

    private var notedSetupIssue: SetupIssue?

    /// Records a diagnostic event without making the caller wait for the disk.
    func record(_ kind: DiagnosticEvent.Kind, _ message: String, _ numbers: [String: Double] = [:]) {
        let event = DiagnosticEvent(timestamp: Date(), kind: kind, message: message, numbers: numbers)
        let client = self.client
        Task { await client.recordDiagnostic(event) }
    }

    private func noteSetupIssue() {
        let issue = setupIssue
        guard issue != notedSetupIssue else { return }
        notedSetupIssue = issue
        guard let issue else { return }
        record(.setupIssue, issue == .gitMissing ? "git is not installed" : "none of the chosen folders can be read")
    }

    /// The text the Diagnostics sheet shows, copies and saves. Names are left out unless asked for.
    func diagnosticsReport(includeNames: Bool) async -> String {
        let events = await client.diagnosticEvents()
        let ghVersion: String?
        if case .installed(let version, _) = toolStatus.gitHubCLI { ghVersion = version } else { ghVersion = nil }
        var problems: [String] = []
        if toolStatusLoaded && toolStatus.gitVersion == nil { problems.append("git is not installed (Apple's command line tools are missing)") }
        let blocked = unreadableFolders.count
        if blocked > 0 { problems.append("\(blocked) of \(settings.folders.filter(\.isEnabled).count) folders cannot be read") }
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "development") (\(info?["CFBundleVersion"] as? String ?? "0"))"
        let input = DiagnosticsInput(
            appVersion: version, osVersion: SystemFacts.osVersion(), architecture: SystemFacts.architecture(),
            gitVersion: toolStatusLoaded ? toolStatus.gitVersion : nil, gitHubCLIVersion: ghVersion, setupProblems: problems,
            settings: settings, folderAccess: settings.folders.filter(\.isEnabled).map { access(of: $0.path) },
            history: history, events: events, repositoryNames: snapshots.map(\.repo.name),
            branchNames: allRows.map(\.title), now: Date())
        return DiagnosticsReport.text(input, includeNames: includeNames)
    }

    // MARK: Work that exists only on this Mac

    /// What the last scan found in the repositories: unpushed commits, uncommitted changes, stashes.
    private(set) var localOnly: [LocalOnlyItem] = []
    /// False until the first look finished, so an empty list is not read as "everything is backed up" too early.
    private(set) var localOnlyLoaded = false

    #if DEBUG
    @ObservationIgnored private var hiddenLocalOnly: [LocalOnlyItem]?

    /// Screenshot mode only: takes the list away for one shot and puts it back for the next.
    func debugHideLocalOnly(_ hide: Bool) {
        if hide, hiddenLocalOnly == nil {
            hiddenLocalOnly = localOnly
            localOnly = []
        } else if !hide, let items = hiddenLocalOnly {
            localOnly = items
            hiddenLocalOnly = nil
        }
    }
    #endif

    func scanLocalOnly() async {
        let found = await client.localOnlyWork(for: snapshots)
        guard !Task.isCancelled else { return }
        localOnly = found
        localOnlyLoaded = true
    }

    // MARK: Setup problems

    /// Whether each folder could be opened at the last check, keyed by canonical path.
    private(set) var folderAccess: [String: FolderAccess] = [:]
    private var folderAccessChecked = false

    func access(of folder: URL) -> FolderAccess { folderAccess[folder.canonicalized.path] ?? .ok }

    func refreshFolderAccess() async {
        folderAccess = await client.folderAccess(of: settings.folders.map(\.path))
        folderAccessChecked = true
        noteSetupIssue()
    }

    /// Enabled folders Lopper cannot open right now.
    var unreadableFolders: [FolderSetting] {
        settings.folders.filter { $0.isEnabled && !access(of: $0.path).isReadable }
    }

    /// The copy of `settings` a scan should use: folders that cannot be opened are paused in the copy only.
    private func readableSettings(_ settings: Settings) -> Settings {
        var copy = settings
        for index in copy.folders.indices where !access(of: copy.folders[index].path).isReadable {
            copy.folders[index].isEnabled = false
        }
        return copy
    }

    /// A problem that stops Lopper from doing anything useful until the user fixes it outside the app.
    var setupIssue: SetupIssue? {
        if toolStatusLoaded && toolStatus.gitVersion == nil { return .gitMissing }
        let enabled = settings.folders.filter(\.isEnabled)
        if folderAccessChecked, !enabled.isEmpty, unreadableFolders.count == enabled.count { return .foldersUnreadable }
        return nil
    }

    /// Looks again after the user installed the tools or changed a permission, and scans if that fixed it.
    func recheckSetup() async {
        let hadIssue = setupIssue != nil
        await refreshToolStatus()
        await refreshFolderAccess()
        if hadIssue || !unreadableFolders.isEmpty { startScan() }
    }

    /// How many scanned repositories sit inside `folder`, nested ones included.
    func repositoryCount(inFolder folder: URL) -> Int {
        let prefix = folder.canonicalized.path
        return results.filter {
            let path = $0.repoRoot.canonicalized.path
            return path == prefix || path.hasPrefix(prefix + "/")
        }.count
    }

    /// Stops scanning and listing a repository. Nothing is deleted; it is shown again from Settings, Safety.
    func hideRepository(_ repoRoot: URL) {
        let name = summaries.first { $0.id == repoRoot.path }?.name ?? repoRoot.lastPathComponent
        updateSettings { $0.repos[repoRoot.path, default: RepoOverrides()].isIgnored = true }
        notice = "Hid \(name). You can show it again in Settings, under Safety."
    }

    func showRepository(_ repoRoot: URL) {
        updateSettings {
            guard var overrides = $0.repos[repoRoot.path] else { return }
            overrides.isIgnored = false
            $0.repos[repoRoot.path] = overrides == RepoOverrides() ? nil : overrides
        }
    }

    func removeRepoOverrides(for repoRoot: URL) {
        updateSettings { $0.repos[repoRoot.path] = nil }
    }

    /// Restores every setting to its default. The file as it was is kept as `settings.json.reset-<time>`.
    func resetSettings(now: Date = Date()) {
        store.flush()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        store.backupFile(label: "reset-\(formatter.string(from: now))")
        updateSettings { $0 = Settings() }
    }

    /// One line that says where Lopper is looking, for the Overview footer.
    var foldersSummary: String {
        let names = settings.roots.map { RowMapper.abbreviated($0) }
        guard let first = names.first else { return "No folders chosen" }
        if names.count == 1 { return "Looking in \(first)" }
        return "Looking in \(first) and \(Plural.count(names.count - 1, "more folder"))"
    }

    func addThrowaway(name: String, repoRoot: URL) {
        updateSettings { $0 = $0.addingRepoDisposable(name, for: repoRoot) }
        confirm("Added \(name) to this repository's throwaway names")
    }

    // MARK: Triage and snooze

    /// The rows being worked through: the open repository's list as the workbench shows it.
    private var triageRows: [CleanupRow] {
        guard case .repo(let id) = route else { return [] }
        return visibleRows(forRepo: id)
    }

    var triagePosition: TriagePosition? {
        guard let focusedRowID else { return nil }
        return Triage.position(of: focusedRowID, in: triageRows.map(\.id))
    }

    func focusNextRow() {
        if let next = triagePosition?.nextID { focusedRowID = next }
    }

    func focusPreviousRow() {
        if let previous = triagePosition?.previousID { focusedRowID = previous }
    }

    func isSnoozed(_ row: CleanupRow, now: Date = Date()) -> Bool {
        preferences.snoozes.isSnoozed(row.id, now: now)
    }

    func snoozedUntil(_ row: CleanupRow) -> Date? { preferences.snoozes.until(for: row.id) }

    func snooze(_ row: CleanupRow, for duration: SnoozeDuration, now: Date = Date()) {
        preferences.snooze(row.id, until: duration.date(from: now))
        confirm("Snoozed for \(duration.phrase)")
    }

    func wake(_ row: CleanupRow) {
        preferences.wake(row.id)
        confirm("Back on the list")
    }

    /// Rows that should still ask for attention: everything except what was put aside.
    func rowsToConsider(now: Date = Date()) -> [CleanupRow] {
        allRows.filter { !preferences.snoozes.isSnoozed($0.id, now: now) }
    }

    // MARK: Keeping a branch

    /// Whether this exact branch name is in the repository's own protected list. Matching a global pattern such
    /// as `main` is the repository's rule and is not reported as a choice.
    func isKeptBranch(_ name: String, in repoRoot: URL) -> Bool {
        settings.repos[repoRoot.path]?.protectedPatterns?.contains(name) ?? false
    }

    /// Protects one branch for good. The repository's list starts from the global patterns, so adding a name
    /// never drops a rule that applied before.
    func keepBranch(_ name: String, in repoRoot: URL) {
        updateSettings { settings in
            var overrides = settings.repos[repoRoot.path] ?? RepoOverrides()
            var list = overrides.protectedPatterns ?? settings.protectedPatterns
            guard !list.contains(name) else { return }
            list.append(name)
            overrides.protectedPatterns = list
            settings.repos[repoRoot.path] = overrides
        }
        confirm("Keeping \(name). Lopper will not remove it.")
    }

    func stopKeepingBranch(_ name: String, in repoRoot: URL) {
        updateSettings { settings in
            guard var overrides = settings.repos[repoRoot.path], var list = overrides.protectedPatterns else { return }
            list.removeAll { $0 == name }
            // Back to inheriting the global list when nothing custom is left.
            overrides.protectedPatterns = list == settings.protectedPatterns ? nil : list
            settings.repos[repoRoot.path] = overrides == RepoOverrides() ? nil : overrides
        }
    }

    /// The repository's remote, for building GitHub links from a row.
    func remoteURL(for row: CleanupRow) -> String? {
        snapshots.first { $0.repo.root == row.repoRoot }?.repo.remoteURL
    }

    // MARK: Item details

    private var checkouts: [String: Date?] = [:]
    private var pullRequests: [String: PullRequestStatus?] = [:]

    func lastCheckedOut(for row: CleanupRow) -> Date? { checkouts[row.id] ?? nil }
    func pullRequest(for row: CleanupRow) -> PullRequestStatus? { pullRequests[row.id] ?? nil }
    func hasLoadedPullRequest(for row: CleanupRow) -> Bool { pullRequests[row.id] != nil }

    /// Everything the details panel reads on demand for one item, in parallel and cached.
    func loadDetails(for row: CleanupRow) async {
        async let history: Void = loadHistory(for: row)
        async let checkout: Void = loadCheckout(for: row)
        async let request: Void = loadPullRequest(for: row)
        _ = await (history, checkout, request)
    }

    private func loadCheckout(for row: CleanupRow) async {
        guard checkouts[row.id] == nil else { return }
        let date = await client.lastCheckedOut(branch: row.title, in: row.path ?? row.repoRoot)
        checkouts[row.id] = .some(date)
    }

    private func loadPullRequest(for row: CleanupRow) async {
        guard pullRequests[row.id] == nil else { return }
        let status = await client.pullRequestStatus(branch: row.title, repoRoot: row.repoRoot)
        pullRequests[row.id] = .some(status)
    }

    // MARK: Branch history

    private var histories: [String: BranchHistory] = [:]

    private func historyKey(_ row: CleanupRow) -> String { "\(row.id)@\(row.facts.tip ?? "")" }

    func branchHistory(for row: CleanupRow) -> BranchHistory? { histories[historyKey(row)] }

    /// Reads the commits only this item has. Cached per item and commit, so selecting around is free.
    func loadHistory(for row: CleanupRow) async {
        let key = historyKey(row)
        guard histories[key] == nil, let ref = row.facts.tip else { return }
        let history = await client.branchHistory(
            repoRoot: row.repoRoot, ref: ref, base: row.facts.defaultBranch)
        histories[key] = history
    }

    // MARK: Confirmations

    /// A short message saying what an action just did, for actions that would otherwise be silent (a copy, a
    /// menu item). In-place buttons confirm themselves; this is for the ones that cannot.
    private(set) var confirmation: String?
    var confirmationDuration: Duration = .seconds(2)
    @ObservationIgnored var copyHandler: (String) -> Void = { OpenActions.copy($0) }
    @ObservationIgnored private var confirmationTask: Task<Void, Never>?

    func confirm(_ message: String) {
        confirmation = message
        confirmationTask?.cancel()
        let duration = confirmationDuration
        confirmationTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.confirmation = nil
        }
    }

    func copy(_ string: String, confirming message: String) {
        copyHandler(string)
        confirm(message)
    }

    // MARK: Scanning

    func scanIfStale(maxAge: TimeInterval = 300) {
        guard !isScanning, !isCleaning, !settings.roots.isEmpty else { return }
        if let lastScan, Date().timeIntervalSince(lastScan) < maxAge { return }
        startScan()
    }

    func startScan() {
        guard !settings.roots.isEmpty, !isCleaning else { return }
        scanTask?.cancel()
        let progressive = results.isEmpty
        phase = .scanning(done: 0, total: 0)
        let scanStarted = Date()
        scanTask = Task {
            await refreshFolderAccess()
            guard !Task.isCancelled else { return }
            // A folder macOS refuses to open is left out, so one blocked folder never hides the others.
            let settings = readableSettings(self.settings)
            if settings.roots.isEmpty {
                results = []
                measuredPaths = []
                phase = .ready(Date())
                return
            }
            var collected: [RepoScanResult] = []
            var total = 0
            for await event in client.scan(settings: settings) {
                switch event {
                case .discovered(let count):
                    total = count
                    phase = .scanning(done: 0, total: count)
                case .result(let result):
                    collected.append(result)
                    phase = .scanning(done: collected.count, total: total)
                    if progressive { results = Self.sorted(collected) }
                }
            }
            guard !Task.isCancelled else { return }
            results = Self.sorted(collected)
            measuredPaths = []
            // A repository that no longer exists must not stay selected as the current screen.
            if case .repo(let id) = route, !results.contains(where: { $0.repoRoot.path == id }) {
                route = .overview
            }
            let finished = Date()
            lastCompletedScan = finished
            phase = .ready(finished)
            await reloadHistory()
            let sizesStarted = Date()
            await measureSizes()
            record(
                .scanFinished, "",
                ["repositories": Double(snapshots.count), "failures": Double(results.count - snapshots.count),
                 "scanSeconds": sizesStarted.timeIntervalSince(scanStarted),
                 "sizeSeconds": Date().timeIntervalSince(sizesStarted)])
            for case .failure(let root, let message) in results {
                record(.scanFailure, "\(root.lastPathComponent): \(message)")
            }
            await scanLocalOnly()
            await scanArtifacts()
            await sendDigestIfDue()
        }
    }

    private static func sorted(_ results: [RepoScanResult]) -> [RepoScanResult] {
        results.sorted { $0.repoRoot.path < $1.repoRoot.path }
    }

    /// Folder sizes arrive one by one after the listing is on screen: every worktree, and every main folder
    /// without the worktrees nested inside it (those are counted under their own name).
    func measureSizes(only paths: Set<String>? = nil) async {
        let targets = snapshots.flatMap { snapshot -> [(path: URL, disposable: Set<String>, excluding: [URL])] in
            let disposable = settings.disposableSet(for: snapshot.repo.root)
            let live = snapshot.worktrees.filter { !$0.isPrunable }
            return live.map { entry in
                let nested = entry.isMain
                    ? live.filter { !$0.isMain && $0.path.path.hasPrefix(entry.path.path + "/") }.map(\.path)
                    : []
                return (path: entry.path, disposable: disposable, excluding: nested)
            }
        }
        .filter { paths?.contains($0.path.path) ?? true }
        let client = self.client
        await withTaskGroup(of: (String, DiskUsage).self) { group in
            var iterator = targets.makeIterator()
            func addNext() {
                guard let target = iterator.next() else { return }
                group.addTask {
                    (target.path.path,
                     await client.measure(target.path, disposable: target.disposable, excluding: target.excluding))
                }
            }
            for _ in 0..<4 { addNext() }
            while let (path, usage) = await group.next() {
                sizes[path] = usage
                measuredPaths.insert(path)
                addNext()
            }
        }
    }

    // MARK: Agents

    var agentPolicy: AgentPolicy {
        var policy = AgentPolicy(settings: settings)
        policy.keptPaths = preferences.keptWorktrees
        return policy
    }

    func setWorktreeKept(_ row: CleanupRow, _ kept: Bool) {
        guard let path = row.path?.path else { return }
        preferences.setWorktreeKept(path, kept)
        // The kept set is part of the agent policy the rows are built from.
        invalidateRows()
    }

    /// Every detected agent worktree, loudest first, then oldest activity first.
    var agentRows: [AgentRow] {
        snapshots
            .flatMap { mappedRows($0) }
            .compactMap { row in row.agent.map { AgentRow(row: row, assessment: $0) } }
            .sorted {
                if $0.stateSort != $1.stateSort { return $0.stateSort < $1.stateSort }
                if $0.activitySort != $1.activitySort { return $0.activitySort < $1.activitySort }
                return $0.title < $1.title
            }
    }

    var visibleAgentRows: [AgentRow] {
        let needle = agentSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        return agentRows.filter { item in
            agentFilter.matches(item.assessment.state)
                && (agentToolFilter == nil || item.assessment.detection.tool == agentToolFilter)
                && (needle.isEmpty
                    || item.title.lowercased().contains(needle)
                    || item.row.location.lowercased().contains(needle)
                    || item.row.repoName.lowercased().contains(needle))
        }
    }

    /// What "Reclaim finished" removes: measured, merged, clean, idle, and not unticked by the user.
    var reclaimableAgentRows: [AgentRow] {
        agentRows.filter { $0.assessment.isReclaimable && !agentExcluded.contains($0.id) }
    }

    var abandonedAgentRows: [AgentRow] {
        agentRows.filter { $0.assessment.isReviewReclaimable && !agentExcluded.contains($0.id) }
    }

    var agentsSummary: AgentsSummary {
        var summary = AgentsSummary()
        for item in agentRows {
            let assessment = item.assessment
            summary.total += 1
            if !assessment.isActivityMeasured && assessment.state != .protected { summary.measuring += 1 }
            if assessment.isReclaimable {
                summary.reclaimable += 1
                summary.reclaimableBytes += item.row.size ?? 0
            }
            if assessment.isReviewReclaimable {
                summary.abandonedReclaimable += 1
                summary.abandonedBytes += item.row.size ?? 0
            }
            switch assessment.state {
            case .unmerged, .abandoned: summary.notMerged += 1
            case .active: summary.active += 1
            case .protected: summary.protected += 1
            case .finished: break
            }
            if assessment.uniqueWork.existsOnlyInFolder { summary.folderOnly += 1 }
        }
        return summary
    }

    var failedRepositoryCount: Int {
        results.filter { if case .failure = $0 { true } else { false } }.count
    }

    var agentsPageState: AgentsPageState {
        if settings.roots.isEmpty { return .needsFolders }
        if agentRows.isEmpty {
            if isScanning || (results.isEmpty && phase == .idle) { return .scanning }
            return .noAgents(repositories: summaries.count)
        }
        return agentsSummary.reclaimable == 0 ? .nothingToReclaim : .ready
    }

    func setAgentIncluded(_ id: String, _ included: Bool) {
        if included { agentExcluded.remove(id) } else { agentExcluded.insert(id) }
    }

    func beginReclaimFinishedAgents() {
        beginClean(rows: reclaimableAgentRows.map(\.row))
    }

    func beginReclaimAbandonedAgents() {
        beginClean(rows: abandonedAgentRows.map(\.row))
    }

    /// Sends one not-merged or abandoned row to the Review sheet. Rows that hold work only in the folder,
    /// active rows and unmeasured rows never get there.
    func beginReview(row: CleanupRow) {
        guard let agent = row.agent, agent.canReview else { return }
        beginClean(rows: [row])
    }

    // MARK: Selection

    func checkAllSafe(inRepo id: String? = nil) {
        let rows = id.map(visibleRows(forRepo:)) ?? allRows
        checked.formUnion(rows.filter(\.isBulkEligible).map(\.id))
    }

    func clearChecked() { checked.removeAll() }

    // MARK: Cleaning

    func beginCleanAllSafe() {
        beginClean(rows: allRows.filter(\.isBulkEligible))
    }

    /// Opens the review sheet with one repository's safe items. The sheet is still the only way anything is
    /// removed, so a button on a card is a shortcut to the same safety step and not around it.
    func beginCleanSafe(inRepo id: String) {
        beginClean(rows: rows(forRepo: id).filter(\.isBulkEligible))
    }

    /// Opens a repository, optionally narrowed to one verdict.
    func openRepository(_ id: String, showing filter: VerdictFilter = .all) {
        verdictFilter = filter
        route = .repo(id)
    }

    /// Where to look first when there is something to review.
    var repositoryWithMostToReview: RepoSummary? {
        summaries.filter { $0.review > 0 }.min {
            if $0.review != $1.review { return $0.review > $1.review }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func beginCleanChecked() {
        beginClean(rows: checkedRows)
    }

    func beginClean(rows: [CleanupRow]) {
        guard !settingsNeedAttention else { notice = Self.settingsAttentionNotice; return }
        guard !rows.isEmpty, clean == nil else { return }
        clean = CleanState(rows: rows)
    }

    func dismissClean() {
        guard !isCleaning else { return }
        // Closing a finished sheet any way other than "Done" must still refresh what is listed.
        if clean?.phase == .finished {
            finishClean()
        } else {
            clean = nil
        }
    }

    func setExcluded(_ id: String, _ excluded: Bool) {
        guard var state = clean, state.phase == .review else { return }
        if excluded { state.excluded.insert(id) } else { state.excluded.remove(id) }
        clean = state
    }

    func runClean() {
        guard var state = clean, state.phase == .review else { return }
        let rowsByItemID = Dictionary(uniqueKeysWithValues: state.includedRows.compactMap { row in
            row.cleanupItem.map { ($0.id, row) }
        })
        let items = state.includedRows.compactMap(\.cleanupItem)
        // Every agent worktree is removed under the Agents page's promise: nothing may exist only in its
        // folder at the moment of removal, however it was approved.
        let strictIDs = Set(state.includedRows.filter { $0.agent != nil }.compactMap { $0.cleanupItem?.id })
        // What each removal frees, for History. Only worktrees have a size of their own.
        var sizeHints: [String: Int64] = [:]
        for row in state.includedRows {
            if let item = row.cleanupItem, let size = row.size { sizeHints[item.id] = size }
        }
        guard !items.isEmpty else { return }
        state.phase = .running(done: 0, total: items.count)
        clean = state
        scanTask?.cancel()
        if isScanning {
            // The cancelled scan will never report back; do not leave the app looking like it is scanning.
            phase = lastCompletedScan.map(ScanPhase.ready) ?? .idle
        }
        let settings = self.settings
        cleanControl = BatchControl()
        let control = cleanControl

        cleanTask = Task {
            for await event in client.clean(
                items, settings: settings, control: control, strictItemIDs: strictIDs, sizeHints: sizeHints
            ) {
                guard var current = clean else { break }
                switch event {
                case .started(let batchID, let total):
                    current.batchID = batchID
                    current.phase = .running(done: 0, total: total)
                case .itemFinished(_, let item, let outcome):
                    let row = rowsByItemID[item.id]
                    let title = row?.title ?? Self.title(of: item)
                    current.outcomes.append(Self.outcome(id: item.id, title: title, outcome))
                    switch outcome {
                    case .skipped(let reason): record(.cleanProblem, "\(title) skipped: \(reason)")
                    case .failed(let message): record(.cleanProblem, "\(title) failed: \(message)")
                    case .removed: break
                    }
                    if case .removed = outcome, row != nil {
                        current.reclaimedBytes += row?.size ?? 0
                        current.removedRows += 1
                    }
                    if case .running(_, let total) = current.phase {
                        current.phase = .running(done: current.outcomes.count, total: total)
                    }
                case .finished(let summary):
                    current.phase = .finished
                    current.batchID = summary.batchID
                    if summary.removed > 0 {
                        // The toast counts what was selected, so it matches the sheet and History.
                        toast = UndoToast(
                            id: summary.batchID, removed: max(current.removedRows, 1),
                            reclaimed: current.reclaimedBytes)
                    }
                }
                clean = current
            }
            if case .running = clean?.phase { clean?.phase = .finished }
            checked.removeAll()
            await reloadHistory()
        }
    }

    /// Stops after the item in flight. Cancelling the task instead would interrupt a removal half way.
    func cancelClean() {
        guard case .running = clean?.phase else { return }
        cleanControl.requestStop()
        clean?.isStopping = true
    }

    func finishClean() {
        clean = nil
        startScan()
    }

    private static func title(of item: CleanupItem) -> String {
        switch item {
        case .branch(_, let name, _): name
        case .worktree(_, let path, _, _): path.lastPathComponent
        }
    }

    private static func outcome(id: String, title: String, _ outcome: CleanOutcome) -> ItemOutcome {
        switch outcome {
        case .removed: ItemOutcome(id: id, title: title, status: .removed, message: nil)
        case .skipped(let reason): ItemOutcome(id: id, title: title, status: .skipped, message: reason)
        case .failed(let message): ItemOutcome(id: id, title: title, status: .failed, message: message)
        }
    }

    // MARK: Undo and history

    /// Reads the undo log and, with it, which cleared folders are still waiting in the Trash.
    func reloadHistory() async {
        history = await client.history()
        trashedFolders = await client.trashedFolders()
    }

    func undoToast() {
        guard let toast else { return }
        self.toast = nil
        Task {
            report(await client.restoreBatch(toast.id))
            await reloadHistory()
            startScan()
        }
    }

    func dismissToast() { toast = nil }

    func dismissNotice() { notice = nil }

    private func report(_ outcomes: [RestoreOutcome]) {
        let failures = outcomes.compactMap { outcome -> String? in
            if case .failed(let message) = outcome { message } else { nil }
        }
        // A worktree and its branch are two records and one item.
        let restored = HistoryCounts.items(in: outcomes.compactMap { outcome -> UndoRecord? in
            if case .restored(let record) = outcome { record } else { nil }
        })
        for message in failures { record(.restoreProblem, message) }
        guard let first = failures.first else {
            notice = nil
            if restored > 0 { confirm("Restored \(Plural.count(restored, "item"))") }
            return
        }
        notice = "Couldn't restore \(Plural.count(failures.count, "item")). \(first)"
    }

    func restoreBatch(_ id: UUID) {
        Task {
            report(await client.restoreBatch(id))
            await reloadHistory()
            startScan()
        }
    }

    /// Restores one history entry: the branch first, so a worktree can be re-attached to it.
    func restore(_ entry: HistoryEntry) {
        let records = entry.records.filter { $0.status == .completed }
        Task {
            var outcomes: [RestoreOutcome] = []
            for record in records { outcomes.append(await client.restore(record)) }
            report(outcomes)
            await reloadHistory()
            startScan()
        }
    }

    func restore(_ record: UndoRecord) {
        Task {
            report([await client.restore(record)])
            await reloadHistory()
            startScan()
        }
    }
}

#if DEBUG
extension AppModel {
    /// A model with its state filled in directly, for previews and screenshots. It never scans.
    static func preview(
        snapshots: [RepoSnapshot] = [Fixtures.sample],
        sizes: [String: Int64] = ["/code/wt/feat/in-worktree": 1_240_000_000],
        activity: [String: Date] = [:],
        roots: [URL] = [URL(fileURLWithPath: "/code")],
        history: [UndoRecord] = [],
        route: Route = .overview,
        phase: ScanPhase? = nil,
        focusedRowID: String? = nil,
        failures: [URL] = [],
        artifacts: [DiskArtifact] = Fixtures.diskArtifacts,
        developerCaches: [DiskArtifact] = Fixtures.developerCaches,
        volume: VolumeSpace? = VolumeSpace(total: 994_000_000_000, available: 142_000_000_000),
        suggestions: [FolderSuggestion] = Fixtures.folderSuggestions,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) -> AppModel {
        let store = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-preview-settings.json"))
        let client = FakeEngineClient(snapshots: snapshots)
        client.historyRecords = history
        // A rescan (the window starts one) must find the same folders the preview was given.
        client.artifactsByRoot = Dictionary(grouping: artifacts, by: { $0.checkoutRoot.path })
        client.caches = developerCaches
        client.suggestions = suggestions
        client.volume = volume
        let model = AppModel(
            client: client,
            store: store,
            settings: Settings(roots: roots),
            now: clock)
        model.results = snapshots.map { .snapshot($0) }
            + failures.map { .failure(repoRoot: $0, message: "git couldn't complete this step: not a git repository") }
        var usage: [String: DiskUsage] = [:]
        for path in Set(sizes.keys).union(activity.keys) {
            usage[path] = DiskUsage(total: sizes[path] ?? 0, disposable: 0, newestModification: activity[path])
        }
        model.sizes = usage
        model.measuredPaths = Set(usage.keys)
        model.history = history
        model.artifacts = artifacts
        model.developerCaches = developerCaches
        model.volumeSpace = volume
        model.artifactPhase = .ready(Date())
        model.route = route
        model.phase = phase ?? .ready(Date())
        model.focusedRowID = focusedRowID
        return model
    }
}
#endif

