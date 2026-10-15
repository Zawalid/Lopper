import XCTest
@testable import LopperApp

final class SidebarLayoutTests: XCTestCase {
    private func summary(
        _ name: String, in folder: String = "/code", safe: Int = 0, review: Int = 0, protected: Int = 0,
        failure: String? = nil
    ) -> RepoSummary {
        RepoSummary(
            id: "\(folder)/\(name)", name: name, root: URL(fileURLWithPath: "\(folder)/\(name)"),
            safeBranches: safe, safeWorktrees: 0, review: review, protected: protected,
            reclaimableBytes: 0, defaultBranch: "main", failure: failure)
    }

    private let folders = [URL(fileURLWithPath: "/code"), URL(fileURLWithPath: "/work")]

    private func sections(
        _ summaries: [RepoSummary], _ grouping: SidebarGrouping, query: String = ""
    ) -> [SidebarSection] {
        SidebarLayout.sections(summaries: summaries, grouping: grouping, folders: folders, query: query)
    }

    // MARK: By attention

    func testAttentionGroupingSplitsNeedsAttentionFromTidyAndOmitsEmptySections() {
        let all = [
            summary("tidy-b"), summary("busy", safe: 3), summary("tidy-a"), summary("looks", review: 2),
            summary("broken", failure: "not a repository"),
        ]
        let result = sections(all, .attention)

        XCTAssertEqual(result.map(\.id), ["attention", "tidy"])
        // Safe items first, then review items, then whatever is left by name.
        XCTAssertEqual(result[0].repos.map(\.name), ["busy", "looks", "broken"])
        XCTAssertEqual(result[1].repos.map(\.name), ["tidy-a", "tidy-b"])
        XCTAssertTrue(result[1].isTidy)
        XCTAssertFalse(result[0].isTidy)
    }

    func testAttentionGroupingWithOnlyTidyRepositoriesHasOneSection() {
        let result = sections([summary("a"), summary("b")], .attention)
        XCTAssertEqual(result.map(\.id), ["tidy"])
    }

    func testRepositoryWithOnlyProtectedBranchesIsTidy() {
        let result = sections([summary("only-main", protected: 1)], .attention)
        XCTAssertEqual(result.map(\.id), ["tidy"])
    }

    // MARK: By folder

    func testFolderGroupingFollowsFolderOrderAndPutsStrangersInOther() {
        let all = [
            summary("w1", in: "/work", safe: 1), summary("c1", in: "/code"), summary("c2", in: "/code", safe: 2),
            summary("stray", in: "/elsewhere"),
        ]
        let result = sections(all, .folder)

        XCTAssertEqual(result.map(\.title), ["code", "work", "Other"])
        XCTAssertEqual(result[0].repos.map(\.name), ["c2", "c1"])
        XCTAssertEqual(result[2].repos.map(\.name), ["stray"])
        XCTAssertFalse(result.contains { $0.isTidy })
    }

    func testFolderGroupingPicksTheMostSpecificFolderForNestedRoots() {
        let nested = [URL(fileURLWithPath: "/code"), URL(fileURLWithPath: "/code/clients")]
        let all = [summary("deep", in: "/code/clients"), summary("shallow", in: "/code")]
        let result = SidebarLayout.sections(summaries: all, grouping: .folder, folders: nested, query: "")

        XCTAssertEqual(result.first { $0.title == "clients" }?.repos.map(\.name), ["deep"])
        XCTAssertEqual(result.first { $0.title == "code" }?.repos.map(\.name), ["shallow"])
    }

    func testFolderTitlesAreDisambiguatedWhenTwoFoldersShareAName() {
        let same = [URL(fileURLWithPath: "/a/projects"), URL(fileURLWithPath: "/b/projects")]
        let all = [summary("x", in: "/a/projects"), summary("y", in: "/b/projects")]
        let result = SidebarLayout.sections(summaries: all, grouping: .folder, folders: same, query: "")

        XCTAssertEqual(Set(result.map(\.title)).count, 2)
    }

    // MARK: Flat and search

    func testFlatGroupingIsOneSectionWithAttentionFirst() {
        let all = [summary("b"), summary("a", safe: 1)]
        let result = sections(all, .flat)

        XCTAssertEqual(result.map(\.id), ["all"])
        XCTAssertEqual(result[0].repos.map(\.name), ["a", "b"])
    }

    func testSearchMatchesNamesCaseInsensitivelyAndDropsEmptySections() {
        let all = [summary("formatex-api", safe: 2), summary("formatex-web"), summary("cli", safe: 1)]
        let result = sections(all, .attention, query: "  FORMATEX ")

        XCTAssertEqual(result.map(\.id), ["attention", "tidy"])
        XCTAssertEqual(result.flatMap(\.repos).map(\.name), ["formatex-api", "formatex-web"])
        XCTAssertTrue(sections(all, .attention, query: "zzz").isEmpty)
    }

    func testSearchFieldAppearsOnlyForLongLists() {
        XCTAssertFalse(SidebarLayout.showsSearch(repositoryCount: 8))
        XCTAssertTrue(SidebarLayout.showsSearch(repositoryCount: 9))
    }
}
