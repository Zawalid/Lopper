import AppKit
import Foundation
import Observation
import Lopper

enum Route: Hashable {
    case overview
    case history
    case repo(String)
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
    var reclaimedBytes: Int64 = 0
    var batchID: UUID?

    /// The user pressed Stop: the item in flight finishes, then the batch ends.
    var isStopping = false

    var includedRows: [CleanupRow] { rows.filter { !excluded.contains($0.id) } }
    var includedBytes: Int64 { includedRows.reduce(0) { $0 + ($1.size ?? 0) } }
    var removedCount: Int { outcomes.filter { $0.status == .removed }.count }
    var problemCount: Int { outcomes.filter { $0.status != .removed }.count }
}

struct UndoToast: Equatable, Identifiable {
    let id: UUID
    let removed: Int
    let reclaimed: Int64
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

    private(set) var settings: Settings
    private(set) var phase: ScanPhase = .idle
    private(set) var results: [RepoScanResult] = []
    private(set) var sizes: [String: DiskUsage] = [:]
    private(set) var history: [UndoRecord] = []

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
    var clean: CleanState?
    var toast: UndoToast?

    /// A short message about something that did not work (for example a restore that was blocked).
    private(set) var notice: String?

    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?
    private var cleanControl = BatchControl()
    private var lastCompletedScan: Date?

    init(
        client: any EngineClient,
        store: SettingsStore = .standard,
        settings: Settings? = nil,
        preferences: AppPreferences = AppPreferences()
    ) {
        self.client = client
        self.store = store
        self.preferences = preferences
        self.routeStorage = preferences.lastRoute
        self.inspectorStorage = preferences.inspectorVisible
        if let settings {
            self.settings = settings
        } else {
            let loaded = store.load()
            self.settings = loaded.settings
            self.notice = Self.notice(for: loaded.outcome)
        }
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
        case .newerVersion(let backup):
            return "Your settings were saved by a newer version of Lopper. They are used as they are, "
                + "and a copy was kept as \(backup.lastPathComponent)."
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
        snapshots.flatMap { RowMapper.rows(for: $0, sizes: sizes) }
    }

    func rows(forRepo id: String) -> [CleanupRow] {
        guard let snapshot = snapshots.first(where: { $0.repo.id == id }) else { return [] }
        return RowMapper.rows(for: snapshot, sizes: sizes)
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
                let rows = RowMapper.rows(for: snapshot, sizes: sizes)
                let safe = rows.filter { $0.verdict == .safe }
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

    var prDetectionNote: Bool {
        !snapshots.isEmpty && snapshots.contains { !$0.prDetectionAvailable }
    }

    // MARK: Settings

    /// Applies a settings change, saves it (debounced), and rescans when the change affects what is found or
    /// how it is decided. Callers never start scans by hand for settings changes.
    func updateSettings(_ change: (inout Settings) -> Void) {
        var copy = settings
        change(&copy)
        guard copy != settings else { return }
        let needsRescan = copy.requiresRescan(comparedTo: settings)
        settings = copy
        store.scheduleSave(copy)
        guard needsRescan else { return }
        if copy.roots.isEmpty {
            // Nothing left to look in: forget everything that came from the removed folders.
            scanTask?.cancel()
            results = []
            sizes = [:]
            checked = []
            focusedRowID = nil
            route = .overview
            phase = .idle
        } else {
            startScan()
        }
    }

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
        let settings = self.settings
        scanTask = Task {
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
            // A repository that no longer exists must not stay selected as the current screen.
            if case .repo(let id) = route, !results.contains(where: { $0.repoRoot.path == id }) {
                route = .overview
            }
            let finished = Date()
            lastCompletedScan = finished
            phase = .ready(finished)
            history = await client.history()
            await measureSizes()
        }
    }

    private static func sorted(_ results: [RepoScanResult]) -> [RepoScanResult] {
        results.sorted { $0.repoRoot.path < $1.repoRoot.path }
    }

    /// Worktree sizes arrive one by one after the listing is on screen.
    func measureSizes() async {
        let targets = snapshots.flatMap { snapshot in
            snapshot.worktrees
                .filter { !$0.isMain && !$0.isPrunable }
                .map { (path: $0.path, disposable: settings.disposableSet(for: snapshot.repo.root)) }
        }
        let client = self.client
        await withTaskGroup(of: (String, DiskUsage).self) { group in
            var iterator = targets.makeIterator()
            func addNext() {
                guard let target = iterator.next() else { return }
                group.addTask {
                    (target.path.path, await client.measure(target.path, disposable: target.disposable))
                }
            }
            for _ in 0..<4 { addNext() }
            while let (path, usage) = await group.next() {
                sizes[path] = usage
                addNext()
            }
        }
    }

    // MARK: Selection

    func checkAllSafe(inRepo id: String? = nil) {
        let rows = id.map(visibleRows(forRepo:)) ?? allRows
        checked.formUnion(rows.filter { $0.verdict == .safe }.map(\.id))
    }

    func clearChecked() { checked.removeAll() }

    // MARK: Cleaning

    func beginCleanAllSafe() {
        beginClean(rows: allRows.filter { $0.verdict == .safe })
    }

    /// Opens the review sheet with one repository's safe items. The sheet is still the only way anything is
    /// removed, so a button on a card is a shortcut to the same safety step and not around it.
    func beginCleanSafe(inRepo id: String) {
        beginClean(rows: rows(forRepo: id).filter { $0.verdict == .safe })
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
            for await event in client.clean(items, settings: settings, control: control) {
                guard var current = clean else { break }
                switch event {
                case .started(let batchID, let total):
                    current.batchID = batchID
                    current.phase = .running(done: 0, total: total)
                case .itemFinished(_, let item, let outcome):
                    let row = rowsByItemID[item.id]
                    let title = row?.title ?? Self.title(of: item)
                    current.outcomes.append(Self.outcome(id: item.id, title: title, outcome))
                    if case .removed = outcome { current.reclaimedBytes += row?.size ?? 0 }
                    if case .running(_, let total) = current.phase {
                        current.phase = .running(done: current.outcomes.count, total: total)
                    }
                case .finished(let summary):
                    current.phase = .finished
                    current.batchID = summary.batchID
                    if summary.removed > 0 {
                        toast = UndoToast(
                            id: summary.batchID, removed: summary.removed, reclaimed: current.reclaimedBytes)
                    }
                }
                clean = current
            }
            if case .running = clean?.phase { clean?.phase = .finished }
            checked.removeAll()
            history = await client.history()
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

    func undoToast() {
        guard let toast else { return }
        self.toast = nil
        Task {
            report(await client.restoreBatch(toast.id))
            history = await client.history()
            startScan()
        }
    }

    func dismissToast() { toast = nil }

    func dismissNotice() { notice = nil }

    private func report(_ outcomes: [RestoreOutcome]) {
        let failures = outcomes.compactMap { outcome -> String? in
            if case .failed(let message) = outcome { message } else { nil }
        }
        let restored = outcomes.filter { if case .restored = $0 { true } else { false } }.count
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
            history = await client.history()
            startScan()
        }
    }

    func restore(_ record: UndoRecord) {
        Task {
            report([await client.restore(record)])
            history = await client.history()
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
        roots: [URL] = [URL(fileURLWithPath: "/code")],
        history: [UndoRecord] = [],
        route: Route = .overview,
        phase: ScanPhase? = nil,
        focusedRowID: String? = nil,
        failures: [URL] = []
    ) -> AppModel {
        let store = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-preview-settings.json"))
        let model = AppModel(
            client: FakeEngineClient(snapshots: snapshots),
            store: store,
            settings: Settings(roots: roots))
        model.results = snapshots.map { .snapshot($0) }
            + failures.map { .failure(repoRoot: $0, message: "git couldn't complete this step: not a git repository") }
        model.sizes = sizes.mapValues { DiskUsage(total: $0, disposable: 0) }
        model.history = history
        model.route = route
        model.phase = phase ?? .ready(Date())
        model.focusedRowID = focusedRowID
        return model
    }
}
#endif

