import AppKit
import Foundation
import Observation

/// Where preference values are kept. Production uses UserDefaults; tests and previews use memory so they never
/// touch (or leave behind) real user defaults.
protocol PreferenceStore: AnyObject {
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool?
    func set(_ value: Any?, forKey key: String)
}

final class MemoryPreferenceStore: PreferenceStore {
    private var values: [String: Any] = [:]

    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool? { values[key] as? Bool }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

final class UserDefaultsPreferenceStore: PreferenceStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? { defaults.string(forKey: key) }

    func bool(forKey key: String) -> Bool? {
        defaults.object(forKey: key) == nil ? nil : defaults.bool(forKey: key)
    }

    func set(_ value: Any?, forKey key: String) { defaults.set(value, forKey: key) }
}

/// Stored form of a screen, so the app can reopen on the page the user left.
enum PreferencesRoute {
    static func encode(_ route: Route) -> String {
        switch route {
        case .overview: "overview"
        case .agents: "agents"
        case .disk: "disk"
        case .history: "history"
        case .repo(let path): "repo:\(path)"
        }
    }

    static func decode(_ value: String?) -> Route {
        guard let value else { return .overview }
        if value == "agents" { return .agents }
        if value == "disk" { return .disk }
        if value == "history" { return .history }
        if value.hasPrefix("repo:"), value.count > "repo:".count {
            return .repo(String(value.dropFirst("repo:".count)))
        }
        return .overview
    }
}

/// How the app looks and behaves. The only place that knows the stored keys; everything else reads these
/// properties and writes through the setters, which persist and apply side effects.
///
/// Settings that change what Lopper decides (folders, protected branches, ...) are not here: they live in the
/// shared engine settings file.
@MainActor
@Observable
final class AppPreferences {
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: Self { self }

        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    /// The stored keys. `editorBundleID` and `showCountInMenuBar` keep the names earlier builds used.
    enum Key: String, CaseIterable {
        case appearance, showInDock, showCountInMenuBar, editorBundleID, terminalBundleID, lastRoute, inspectorVisible
        case sidebarGrouping, sidebarSort, sidebarShowsDetails, sidebarShowsTidy, snoozedItems, keptWorktrees
    }

    /// Things a preference does to the running application, injectable so tests do not change their host.
    struct Effects: Sendable {
        var setAppearance: @MainActor @Sendable (Appearance) -> Void
        var setDockVisible: @MainActor @Sendable (Bool) -> Void

        static let none = Effects(setAppearance: { _ in }, setDockVisible: { _ in })

        static let application = Effects(
            setAppearance: { appearance in
                let app = NSApplication.shared
                switch appearance {
                case .system: app.appearance = nil
                case .light: app.appearance = NSAppearance(named: .aqua)
                case .dark: app.appearance = NSAppearance(named: .darkAqua)
                }
            },
            setDockVisible: { visible in
                let app = NSApplication.shared
                app.setActivationPolicy(visible ? .regular : .accessory)
                if visible { app.activate(ignoringOtherApps: true) }
            })
    }

    @ObservationIgnored private let store: PreferenceStore
    @ObservationIgnored private let effects: Effects

    private(set) var appearance: Appearance
    private(set) var showInDock: Bool
    private(set) var showCountInMenuBar: Bool
    private(set) var editorBundleID: String
    private(set) var terminalBundleID: String
    private(set) var lastRoute: Route
    private(set) var inspectorVisible: Bool
    private(set) var sidebarGrouping: SidebarGrouping
    private(set) var sidebarSort: SidebarSort
    private(set) var sidebarShowsDetails: Bool
    private(set) var sidebarShowsTidy: Bool
    private(set) var snoozes: Snoozes
    /// Agent worktree folders the person asked Lopper to keep.
    private(set) var keptWorktrees: Set<String>

    /// The instance the running app uses: real defaults, real effects.
    static let standard = AppPreferences(
        store: UserDefaultsPreferenceStore(), effects: .application,
        isInstalled: { OpenActions.installed($0) })

    init(
        store: PreferenceStore = MemoryPreferenceStore(),
        effects: Effects = .none,
        isInstalled: @escaping (String) -> Bool = { _ in false }
    ) {
        self.store = store
        self.effects = effects
        appearance = store.string(forKey: Key.appearance.rawValue).flatMap(Appearance.init(rawValue:)) ?? .system
        showInDock = store.bool(forKey: Key.showInDock.rawValue) ?? true
        showCountInMenuBar = store.bool(forKey: Key.showCountInMenuBar.rawValue) ?? false
        editorBundleID = store.string(forKey: Key.editorBundleID.rawValue)
            ?? EditorChoice.allCases.first { isInstalled($0.rawValue) }?.rawValue
            ?? EditorChoice.vscode.rawValue
        terminalBundleID = store.string(forKey: Key.terminalBundleID.rawValue) ?? TerminalChoice.terminal.rawValue
        lastRoute = PreferencesRoute.decode(store.string(forKey: Key.lastRoute.rawValue))
        inspectorVisible = store.bool(forKey: Key.inspectorVisible.rawValue) ?? true
        sidebarGrouping = store.string(forKey: Key.sidebarGrouping.rawValue)
            .flatMap(SidebarGrouping.init(rawValue:)) ?? .attention
        sidebarSort = store.string(forKey: Key.sidebarSort.rawValue).flatMap(SidebarSort.init(rawValue:)) ?? .attention
        sidebarShowsDetails = store.bool(forKey: Key.sidebarShowsDetails.rawValue) ?? true
        sidebarShowsTidy = store.bool(forKey: Key.sidebarShowsTidy.rawValue) ?? true
        snoozes = Snoozes(encoded: store.string(forKey: Key.snoozedItems.rawValue)).pruned(now: Date())
        keptWorktrees = Set(
            store.string(forKey: Key.keptWorktrees.rawValue)
                .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [])
    }

    /// Applies the stored appearance and Dock presence; called once as the app starts.
    func applyAtLaunch() {
        effects.setAppearance(appearance)
        effects.setDockVisible(showInDock)
    }

    func setAppearance(_ value: Appearance) {
        guard value != appearance else { return }
        appearance = value
        store.set(value.rawValue, forKey: Key.appearance.rawValue)
        effects.setAppearance(value)
    }

    func setShowInDock(_ value: Bool) {
        guard value != showInDock else { return }
        showInDock = value
        store.set(value, forKey: Key.showInDock.rawValue)
        effects.setDockVisible(value)
    }

    func setShowCountInMenuBar(_ value: Bool) {
        guard value != showCountInMenuBar else { return }
        showCountInMenuBar = value
        store.set(value, forKey: Key.showCountInMenuBar.rawValue)
    }

    func setEditorBundleID(_ value: String) {
        guard value != editorBundleID else { return }
        editorBundleID = value
        store.set(value, forKey: Key.editorBundleID.rawValue)
    }

    func setTerminalBundleID(_ value: String) {
        guard value != terminalBundleID else { return }
        terminalBundleID = value
        store.set(value, forKey: Key.terminalBundleID.rawValue)
    }

    func setLastRoute(_ value: Route) {
        guard value != lastRoute else { return }
        lastRoute = value
        store.set(PreferencesRoute.encode(value), forKey: Key.lastRoute.rawValue)
    }

    func setSidebarGrouping(_ value: SidebarGrouping) {
        guard value != sidebarGrouping else { return }
        sidebarGrouping = value
        store.set(value.rawValue, forKey: Key.sidebarGrouping.rawValue)
    }

    func setSidebarSort(_ value: SidebarSort) {
        guard value != sidebarSort else { return }
        sidebarSort = value
        store.set(value.rawValue, forKey: Key.sidebarSort.rawValue)
    }

    func setSidebarShowsDetails(_ value: Bool) {
        guard value != sidebarShowsDetails else { return }
        sidebarShowsDetails = value
        store.set(value, forKey: Key.sidebarShowsDetails.rawValue)
    }

    func setSidebarShowsTidy(_ value: Bool) {
        guard value != sidebarShowsTidy else { return }
        sidebarShowsTidy = value
        store.set(value, forKey: Key.sidebarShowsTidy.rawValue)
    }

    func snooze(_ id: String, until date: Date) {
        snoozes = snoozes.snoozing(id, until: date).pruned(now: Date())
        store.set(snoozes.encoded, forKey: Key.snoozedItems.rawValue)
    }

    func wake(_ id: String) {
        snoozes = snoozes.waking(id)
        store.set(snoozes.encoded, forKey: Key.snoozedItems.rawValue)
    }

    func setWorktreeKept(_ path: String, _ kept: Bool) {
        var updated = keptWorktrees
        if kept { updated.insert(path) } else { updated.remove(path) }
        guard updated != keptWorktrees else { return }
        keptWorktrees = updated
        if let data = try? JSONEncoder().encode(updated.sorted()), let text = String(data: data, encoding: .utf8) {
            store.set(text, forKey: Key.keptWorktrees.rawValue)
        }
    }

    func resetSidebarOptions() {
        setSidebarGrouping(.attention)
        setSidebarSort(.attention)
        setSidebarShowsDetails(true)
        setSidebarShowsTidy(true)
    }

    func setInspectorVisible(_ value: Bool) {
        guard value != inspectorVisible else { return }
        inspectorVisible = value
        store.set(value, forKey: Key.inspectorVisible.rawValue)
    }
}

/// AppKit autosaves the widths of every split view column. When the window comes back smaller than it was
/// when those widths were saved (leaving full screen, a different display, a restored smaller frame), the
/// saved widths no longer add up and the layout overflows the window: the sidebar and inspector end up
/// clipped by its edges. The window frame itself is restored separately and is left alone.
enum WindowLayoutDefaults {
    private static let prefix = "NSSplitView Subview Frames"

    static func discardSavedSplitViewFrames(in defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
