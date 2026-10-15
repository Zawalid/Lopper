import XCTest
@testable import LopperApp

final class OpenWithAppsTests: XCTestCase {
    func testOnlyInstalledAppsAreOffered() {
        let installed: Set<String> = [EditorChoice.zed.rawValue, TerminalChoice.ghostty.rawValue]
        let apps = OpenWithApps.available(isInstalled: { installed.contains($0) })

        XCTAssertEqual(Set(apps.map(\.bundleID)), installed)
    }

    func testAppsAreGroupedEditorsThenTerminalsThenGitClients() {
        let all = OpenWithApps.catalog.map(\.bundleID)
        let apps = OpenWithApps.available(isInstalled: { all.contains($0) })
        let categories = apps.map(\.category)

        XCTAssertEqual(categories, categories.sorted { $0.rawValue < $1.rawValue })
        XCTAssertEqual(Set(categories), Set(OpenWithApp.Category.allCases))
    }

    func testTheCatalogHasNoDuplicateBundleIdentifiers() {
        let ids = OpenWithApps.catalog.map(\.bundleID)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    func testThePreferredEditorComesFirstWhenInstalled() {
        let apps = OpenWithApps.available(isInstalled: { _ in true }, preferredEditor: EditorChoice.zed.rawValue)

        XCTAssertEqual(apps.first?.bundleID, EditorChoice.zed.rawValue)
    }

    func testAMissingPreferredEditorFallsBackToTheFirstInstalledOne() {
        let installed: Set<String> = [EditorChoice.xcode.rawValue]
        let apps = OpenWithApps.available(
            isInstalled: { installed.contains($0) }, preferredEditor: EditorChoice.zed.rawValue)

        XCTAssertEqual(apps.first?.bundleID, EditorChoice.xcode.rawValue)
    }

    func testNothingInstalledGivesAnEmptyList() {
        XCTAssertTrue(OpenWithApps.available(isInstalled: { _ in false }).isEmpty)
    }
}
