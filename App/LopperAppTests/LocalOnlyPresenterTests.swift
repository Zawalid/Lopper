import XCTest
import Lopper
@testable import LopperApp

final class LocalOnlyPresenterTests: XCTestCase {
    private let api = URL(fileURLWithPath: "/code/api")
    private let web = URL(fileURLWithPath: "/code/web")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func days(_ count: Int) -> Date { now.addingTimeInterval(-Double(count) * 86_400) }

    private func item(
        _ kind: LocalOnlyItem.Kind, _ title: String, repo: URL, count: Int = 0, age: Int = 1,
        tracked: Bool = false, detail: String = "", push: Bool = false
    ) -> LocalOnlyItem {
        LocalOnlyItem(
            id: "\(kind.rawValue):\(repo.path)#\(title)", kind: kind, repoRoot: repo, repoName: repo.lastPathComponent,
            title: title, detail: detail, count: count, lastTouched: days(age), branch: title,
            pushCommand: push ? "git push \(title)" : nil, hasTrackedChanges: tracked)
    }

    func testRiskOrderPutsCommitsNoBranchHoldsFirstThenTheBiggestUnpushedBranch() {
        let items = [
            item(.stash, "stash@{0}", repo: api),
            item(.uncommittedChanges, "edited", repo: api, count: 1, tracked: true),
            item(.unpushedCommits, "small", repo: api, count: 2),
            item(.unpushedCommits, "big", repo: api, count: 14),
            item(.detachedCommits, "loose", repo: api, count: 1),
            item(.operationInProgress, "rebasing", repo: api),
        ]

        let section = LocalOnlyPresenter.sections(of: items, query: LocalOnlyQuery())[0]

        XCTAssertEqual(section.items.map(\.title), ["loose", "big", "small", "edited", "rebasing", "stash@{0}"])
    }

    func testEqualRiskGoesToTheWorkExposedLongest() {
        let items = [
            item(.unpushedCommits, "newer", repo: api, count: 3, age: 2),
            item(.unpushedCommits, "older", repo: api, count: 3, age: 40),
        ]

        let section = LocalOnlyPresenter.sections(of: items, query: LocalOnlyQuery())[0]

        XCTAssertEqual(section.items.map(\.title), ["older", "newer"])
    }

    func testUntrackedOnlyWorktreesAreSetApartAndTrackedChangesAreNot() {
        let items = [
            item(.uncommittedChanges, "scratch", repo: api, count: 2, tracked: false),
            item(.uncommittedChanges, "edited", repo: api, count: 0, tracked: true),
            item(.unpushedCommits, "work", repo: api, count: 1),
        ]

        let section = LocalOnlyPresenter.sections(of: items, query: LocalOnlyQuery())[0]

        XCTAssertEqual(section.untrackedOnly.map(\.title), ["scratch"])
        XCTAssertEqual(section.items.map(\.title), ["work", "edited"])
        XCTAssertEqual(section.total, 3, "nothing is dropped, only grouped")
    }

    func testRepositoriesWithTheMostUnpushedCommitsComeFirst() {
        let items = [
            item(.unpushedCommits, "a", repo: web, count: 3),
            item(.unpushedCommits, "b", repo: api, count: 20),
            item(.stash, "stash@{0}", repo: URL(fileURLWithPath: "/code/docs")),
        ]

        let names = LocalOnlyPresenter.sections(of: items, query: LocalOnlyQuery()).map(\.repoName)

        XCTAssertEqual(names, ["api", "web", "docs"])
    }

    func testEachFilterKeepsOnlyItsKinds() {
        let items = [
            item(.unpushedCommits, "p", repo: api, count: 1),
            item(.uncommittedChanges, "u", repo: api, tracked: true),
            item(.stash, "s", repo: api),
            item(.detachedCommits, "d", repo: api, count: 1),
            item(.operationInProgress, "o", repo: api),
        ]

        func titles(_ filter: LocalOnlyFilter) -> Set<String> {
            Set(LocalOnlyPresenter.sections(of: items, query: LocalOnlyQuery(filter: filter)).flatMap(\.all).map(\.title))
        }

        XCTAssertEqual(titles(.all), ["p", "u", "s", "d", "o"])
        XCTAssertEqual(titles(.notPushed), ["p"])
        XCTAssertEqual(titles(.uncommitted), ["u"])
        XCTAssertEqual(titles(.other), ["s", "d", "o"])
    }

    func testSearchMatchesBranchRepositoryAndDetailIgnoringCaseAndAccents() {
        let items = [
            item(.unpushedCommits, "fix/Récupération", repo: api, count: 1, detail: "1 commit not on any remote"),
            item(.unpushedCommits, "feature/x", repo: web, count: 1, detail: "1 commit not on any remote"),
        ]

        func titles(_ text: String) -> [String] {
            LocalOnlyPresenter.sections(of: items, query: LocalOnlyQuery(search: text)).flatMap(\.all).map(\.title)
        }

        XCTAssertEqual(titles("recuperation"), ["fix/Récupération"])
        XCTAssertEqual(titles("WEB"), ["feature/x"])
        XCTAssertEqual(Set(titles("remote")), ["fix/Récupération", "feature/x"])
        XCTAssertEqual(Set(titles("  ")), ["fix/Récupération", "feature/x"], "blank search shows everything")
        XCTAssertTrue(titles("nothing like this").isEmpty)
    }

    func testCountsFollowTheSearchButNotTheFilterAndSumTheCommits() {
        let items = [
            item(.unpushedCommits, "a", repo: api, count: 14),
            item(.unpushedCommits, "b", repo: api, count: 6),
            item(.uncommittedChanges, "c", repo: api),
            item(.stash, "stash@{0}", repo: api),
        ]

        let all = LocalOnlyPresenter.counts(of: items)
        XCTAssertEqual([all.all, all.notPushed, all.uncommitted, all.other, all.unpushedCommits], [4, 2, 1, 1, 20])

        let searched = LocalOnlyPresenter.counts(of: items, search: "b")
        XCTAssertEqual(searched.notPushed, 1)
        XCTAssertEqual(searched.unpushedCommits, 6)
    }

    func testOldestAndNewestOrderByDateInsideARepository() {
        let items = [
            item(.stash, "recent", repo: api, age: 1),
            item(.unpushedCommits, "ancient", repo: api, count: 9, age: 90),
            item(.unpushedCommits, "middle", repo: api, count: 1, age: 20),
        ]

        let oldest = LocalOnlyPresenter.sections(of: items, query: LocalOnlyQuery(sort: .oldest))[0].items.map(\.title)
        let newest = LocalOnlyPresenter.sections(of: items, query: LocalOnlyQuery(sort: .newest))[0].items.map(\.title)

        XCTAssertEqual(oldest, ["ancient", "middle", "recent"])
        XCTAssertEqual(newest, ["recent", "middle", "ancient"])
    }

    func testPushCommandsListOnlyUnpushedBranchesThatHaveOne() {
        let items = [
            item(.unpushedCommits, "a", repo: api, count: 2, push: true),
            item(.unpushedCommits, "b", repo: api, count: 1, push: false),
            item(.uncommittedChanges, "c", repo: api, tracked: true),
        ]

        let section = LocalOnlyPresenter.sections(of: items, query: LocalOnlyQuery())[0]

        XCTAssertEqual(section.pushCommands, ["git push a"])
    }

    func testReportListsEveryItemWithItsKindAndAge() {
        let items = [
            item(.unpushedCommits, "feature/x", repo: api, count: 3, age: 11, detail: "3 commits not on any remote"),
            item(.uncommittedChanges, "scratch", repo: api, count: 2, age: 0, detail: "2 untracked files"),
        ]
        let sections = LocalOnlyPresenter.sections(of: items, query: LocalOnlyQuery())

        let report = LocalOnlyPresenter.report(of: sections, now: now)

        XCTAssertTrue(report.contains("api (/code/api)"), report)
        XCTAssertTrue(report.contains("Not pushed: feature/x - 3 commits not on any remote, 11 days ago"), report)
        XCTAssertTrue(report.contains("Uncommitted: scratch - 2 untracked files, 11 days ago".replacingOccurrences(of: "11 days ago", with: "today")), report)
    }

    func testLongAgeWording() {
        func age(_ count: Int) -> String { AgeFormat.long(from: days(count), to: now) }
        XCTAssertEqual(age(0), "today")
        XCTAssertEqual(age(1), "yesterday")
        XCTAssertEqual(age(11), "11 days ago")
        XCTAssertEqual(age(90), "3 months ago")
        XCTAssertEqual(age(800), "2 years ago")
    }

    @MainActor
    func testModelLoadsAnOpenedRowsDetailOnceAndClearsItOnRescan() async throws {
        let target = item(.unpushedCommits, "feature/x", repo: api, count: 2, push: true)
        let client = FakeEngineClient(snapshots: [Fixtures.sample])
        client.localOnly = [target]
        client.localOnlyDetails[target.id] = LocalOnlyDetail(lines: ["abc1234  first", "def5678  second"])
        let store = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-presenter-\(UUID().uuidString).json"))
        let model = AppModel(client: client, store: store, settings: Settings(roots: [api]))
        model.startScan()
        for _ in 0..<300 where !model.localOnlyLoaded { try? await Task.sleep(for: .milliseconds(10)) }

        await model.loadLocalOnlyDetail(target)
        await model.loadLocalOnlyDetail(target)

        XCTAssertEqual(model.localOnlyDetails[target.id]?.lines.count, 2)
        XCTAssertEqual(client.localOnlyDetailRequests, [target.id], "opening the same row again does not read git again")
    }
}
