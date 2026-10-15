import XCTest
import Lopper
@testable import LopperApp

@MainActor
final class AppPreferencesTests: XCTestCase {
    private final class EffectLog: @unchecked Sendable {
        var appearances: [AppPreferences.Appearance] = []
        var dock: [Bool] = []
    }

    private func make(
        store: PreferenceStore = MemoryPreferenceStore(),
        installed: Set<String> = [],
        log: EffectLog = EffectLog()
    ) -> (AppPreferences, EffectLog) {
        let effects = AppPreferences.Effects(
            setAppearance: { log.appearances.append($0) },
            setDockVisible: { log.dock.append($0) })
        return (AppPreferences(store: store, effects: effects, isInstalled: { installed.contains($0) }), log)
    }

    func testTheStoredKeysAreExactlyTheDocumentedOnes() {
        // A typo or a removed key would silently reset a user's choice, so the list is pinned here.
        XCTAssertEqual(
            AppPreferences.Key.allCases.map(\.rawValue).sorted(),
            ["appearance", "editorBundleID", "inspectorVisible", "lastRoute", "showCountInMenuBar",
             "showInDock", "sidebarGrouping", "sidebarShowsDetails", "sidebarShowsTidy", "sidebarSort",
             "terminalBundleID"])
    }

    func testSidebarGroupingDefaultsToAttentionAndIsRemembered() {
        let store = MemoryPreferenceStore()
        let (first, _) = make(store: store)
        XCTAssertEqual(first.sidebarGrouping, .attention)

        first.setSidebarGrouping(.folder)
        let (second, _) = make(store: store)
        XCTAssertEqual(second.sidebarGrouping, .folder)
    }

    func testSidebarOptionsDefaultsAndPersistence() {
        let store = MemoryPreferenceStore()
        let (first, _) = make(store: store)
        XCTAssertEqual(first.sidebarSort, .attention)
        XCTAssertTrue(first.sidebarShowsDetails)
        XCTAssertTrue(first.sidebarShowsTidy)

        first.setSidebarSort(.size)
        first.setSidebarShowsDetails(false)
        first.setSidebarShowsTidy(false)
        let (second, _) = make(store: store)
        XCTAssertEqual(second.sidebarSort, .size)
        XCTAssertFalse(second.sidebarShowsDetails)
        XCTAssertFalse(second.sidebarShowsTidy)
    }

    func testResettingTheSidebarOptionsRestoresEveryDefault() {
        let (prefs, _) = make()
        prefs.setSidebarGrouping(.folder)
        prefs.setSidebarSort(.name)
        prefs.setSidebarShowsDetails(false)
        prefs.setSidebarShowsTidy(false)

        prefs.resetSidebarOptions()

        XCTAssertEqual(prefs.sidebarGrouping, .attention)
        XCTAssertEqual(prefs.sidebarSort, .attention)
        XCTAssertTrue(prefs.sidebarShowsDetails)
        XCTAssertTrue(prefs.sidebarShowsTidy)
    }

    func testAnUnknownStoredGroupingFallsBackToAttention() {
        let store = MemoryPreferenceStore()
        store.set("by-colour", forKey: AppPreferences.Key.sidebarGrouping.rawValue)
        let (prefs, _) = make(store: store)
        XCTAssertEqual(prefs.sidebarGrouping, .attention)
    }

    func testDefaults() {
        let (prefs, _) = make(installed: [EditorChoice.cursor.rawValue, EditorChoice.zed.rawValue])

        XCTAssertEqual(prefs.appearance, .system)
        XCTAssertTrue(prefs.showInDock)
        XCTAssertFalse(prefs.showCountInMenuBar)
        XCTAssertEqual(prefs.terminalBundleID, TerminalChoice.terminal.rawValue)
        XCTAssertEqual(prefs.editorBundleID, EditorChoice.cursor.rawValue, "the first installed editor, in list order")
        XCTAssertEqual(prefs.lastRoute, .overview)
        XCTAssertTrue(prefs.inspectorVisible)
    }

    func testValuesSurviveANewInstanceOverTheSameStore() {
        let store = MemoryPreferenceStore()
        let (first, _) = make(store: store)
        first.setAppearance(.dark)
        first.setShowInDock(false)
        first.setShowCountInMenuBar(true)
        first.setEditorBundleID(EditorChoice.zed.rawValue)
        first.setTerminalBundleID(TerminalChoice.ghostty.rawValue)
        first.setLastRoute(.repo("/code/api"))
        first.setInspectorVisible(false)

        let (second, _) = make(store: store)

        XCTAssertEqual(second.appearance, .dark)
        XCTAssertFalse(second.showInDock)
        XCTAssertTrue(second.showCountInMenuBar)
        XCTAssertEqual(second.editorBundleID, EditorChoice.zed.rawValue)
        XCTAssertEqual(second.terminalBundleID, TerminalChoice.ghostty.rawValue)
        XCTAssertEqual(second.lastRoute, .repo("/code/api"))
        XCTAssertFalse(second.inspectorVisible)
    }

    func testUserDefaultsBackedStoreRoundTripsAndKeepsLegacyKeyNames() throws {
        let suite = "lopper-prefs-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Values written by earlier builds through @AppStorage with these exact keys must still be read.
        defaults.set("com.apple.dt.Xcode", forKey: "editorBundleID")
        defaults.set(true, forKey: "showCountInMenuBar")

        let (prefs, _) = make(store: UserDefaultsPreferenceStore(defaults: defaults))

        XCTAssertEqual(prefs.editorBundleID, "com.apple.dt.Xcode")
        XCTAssertTrue(prefs.showCountInMenuBar)
        prefs.setAppearance(.light)
        XCTAssertEqual(defaults.string(forKey: "appearance"), "light")
    }

    func testChangesApplyEffectsAndLaunchAppliesCurrentValues() {
        let store = MemoryPreferenceStore()
        let (prefs, log) = make(store: store)

        prefs.setAppearance(.dark)
        prefs.setShowInDock(false)
        XCTAssertEqual(log.appearances, [.dark])
        XCTAssertEqual(log.dock, [false])

        let (relaunched, relaunchLog) = make(store: store)
        relaunched.applyAtLaunch()
        XCTAssertEqual(relaunchLog.appearances, [.dark])
        XCTAssertEqual(relaunchLog.dock, [false])
    }

    func testSettingTheSameValueAgainDoesNotReapplyEffects() {
        let (prefs, log) = make()
        prefs.setAppearance(.dark)
        prefs.setAppearance(.dark)
        XCTAssertEqual(log.appearances, [.dark])
    }

    func testRouteEncodingRoundTripsAndFallsBackToOverview() {
        for route in [Route.overview, .history, .repo("/Users/me/My Projects/api")] {
            XCTAssertEqual(PreferencesRoute.decode(PreferencesRoute.encode(route)), route)
        }
        XCTAssertEqual(PreferencesRoute.decode("nonsense"), .overview)
        XCTAssertEqual(PreferencesRoute.decode("repo:"), .overview)
        XCTAssertEqual(PreferencesRoute.decode(nil), .overview)
    }

    func testNoSourceFileOutsidePreferencesTouchesUserDefaultsDirectly() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LopperApp")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard url.lastPathComponent != "AppPreferences.swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("@AppStorage") || text.contains("UserDefaults") {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [], "preferences are read and written only through AppPreferences")
    }

    // MARK: Model integration

    func testTheModelStartsWhereTheUserLeftOffAndRemembersWhereTheyGo() {
        let store = MemoryPreferenceStore()
        let (prefs, _) = make(store: store)
        prefs.setLastRoute(.history)
        prefs.setInspectorVisible(false)

        let model = AppModel(
            client: FakeEngineClient(snapshots: []),
            store: SettingsStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("lopper-pref-model-\(UUID().uuidString).json")),
            settings: Settings(roots: [URL(fileURLWithPath: "/code")]),
            preferences: prefs)

        XCTAssertEqual(model.route, .history)
        XCTAssertFalse(model.showInspector)

        model.route = .repo("/code/api")
        model.showInspector = true
        XCTAssertEqual(prefs.lastRoute, .repo("/code/api"))
        XCTAssertTrue(prefs.inspectorVisible)
    }

    func testAStoredRepositoryThatNoLongerExistsFallsBackToOverviewAfterTheScan() async {
        let (prefs, _) = make()
        prefs.setLastRoute(.repo("/code/gone"))
        let model = AppModel(
            client: FakeEngineClient(snapshots: [Fixtures.sample]),
            store: SettingsStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("lopper-pref-gone-\(UUID().uuidString).json")),
            settings: Settings(roots: [URL(fileURLWithPath: "/code")]),
            preferences: prefs)
        XCTAssertEqual(model.route, .repo("/code/gone"))

        model.startScan()
        for _ in 0..<300 {
            if case .ready = model.phase { break }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.route, .overview)
        XCTAssertEqual(prefs.lastRoute, .overview)
    }
}
