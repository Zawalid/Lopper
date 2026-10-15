import XCTest
import Lopper
@testable import LopperApp

@MainActor
final class CommandPaletteTests: XCTestCase {
    private func item(_ title: String, _ subtitle: String = "", kind: PaletteItem.Kind = .item) -> PaletteItem {
        PaletteItem(id: title + subtitle, title: title, subtitle: subtitle, symbol: "circle", kind: kind, target: .route(.overview))
    }

    func testAnEmptyQueryOffersPagesAndActionsOnly() {
        let items = [
            item("Overview", kind: .page), item("Rescan", kind: .action),
            item("feat/login"), item("api", kind: .repository),
        ]

        let shown = CommandPalette.search(items, query: "  ")

        XCTAssertEqual(shown.map(\.title), ["Overview", "Rescan"])
    }

    func testPrefixBeatsWordStartBeatsContains() {
        let items = [
            item("old-feature-flag"), item("flag-cleanup"), item("superflagpole"),
        ]

        let titles = CommandPalette.search(items, query: "flag").map(\.title)

        XCTAssertEqual(titles.first, "flag-cleanup", "prefix match first")
        XCTAssertEqual(Set(titles), Set(items.map(\.title)))
        XCTAssertLessThan(titles.firstIndex(of: "old-feature-flag")!, titles.firstIndex(of: "superflagpole")!,
                          "a word start beats a match in the middle of a word")
    }

    func testMatchingIgnoresCaseAndAlsoLooksAtTheSubtitle() {
        let items = [item("node_modules", "Formatex Web, 1,2 GB"), item("dist", "api")]

        XCTAssertEqual(CommandPalette.search(items, query: "FORMATEX").map(\.title), ["node_modules"])
    }

    func testLettersInOrderMatchLikeATypedAbbreviation() {
        let items = [item("History"), item("Hide sidebar")]

        XCTAssertEqual(CommandPalette.search(items, query: "hst").map(\.title), ["History"])
    }

    func testNothingMatchesNonsense() {
        XCTAssertTrue(CommandPalette.search([item("Overview")], query: "zzzq").isEmpty)
    }

    func testTheModelOffersPagesActionsRepositoriesItemsAndFolders() {
        let model = AppModel.preview(route: .overview)
        let items = model.paletteItems()
        let kinds = Set(items.map(\.kind))

        XCTAssertTrue(kinds.isSuperset(of: [.page, .action, .repository, .item]))
        XCTAssertTrue(items.contains { $0.title == "Disk" && $0.kind == .page })
        XCTAssertTrue(items.contains { $0.title == "node_modules" && $0.kind == .folder })
    }

    func testPerformingAPageItemNavigatesThere() {
        let model = AppModel.preview(route: .overview)
        let disk = model.paletteItems().first { $0.title == "Disk" }!

        model.perform(disk)

        XCTAssertEqual(model.route, .disk)
    }

    func testPerformingAFolderItemOpensTheReviewSheet() {
        let model = AppModel.preview(route: .overview)
        let folder = model.paletteItems().first { $0.kind == .folder && $0.title == "node_modules" }!

        model.perform(folder)

        XCTAssertNotNil(model.diskClear)
    }
}
