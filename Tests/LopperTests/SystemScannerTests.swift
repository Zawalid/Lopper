import XCTest
@testable import Lopper

final class SystemScannerTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-sys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        home = home.resolvingSymlinksInPath()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    private func repo(_ relative: String) throws {
        let url = home.appendingPathComponent(relative).appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func folder(_ relative: String) throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(relative), withIntermediateDirectories: true)
    }

    private func scan(maxDepth: Int = 5) async -> [DiscoveredFolder] {
        var result: [DiscoveredFolder] = []
        for await event in SystemScanner(maxDepth: maxDepth).scan(home: home) {
            if case .finished(let folders) = event { result = folders }
        }
        return result
    }

    private func names(_ folders: [DiscoveredFolder]) -> [String] {
        folders.map { $0.path.path.replacingOccurrences(of: home.path + "/", with: "") }.sorted()
    }

    func testReposAreGroupedUnderTheFolderThatHoldsThem() async throws {
        try repo("Projects/api")
        try repo("Projects/web")
        try repo("Code/tool")

        let found = await scan()

        XCTAssertEqual(names(found), ["Code", "Projects"])
        XCTAssertEqual(found.first { $0.path.lastPathComponent == "Projects" }?.repoCount, 2)
    }

    func testNestedGroupsFoldIntoTheFolderAboveThem() async throws {
        try repo("Projects/api")
        try repo("Projects/clients/acme/site")
        try repo("Projects/clients/globex/app")

        let found = await scan()

        XCTAssertEqual(names(found), ["Projects"], "one folder to scan, not three")
        XCTAssertEqual(found.first?.repoCount, 3)
    }

    func testRepositoriesDirectlyInTheHomeFolderAreOfferedOneByOneNotAsTheWholeHome() async throws {
        try repo("loose-repo")
        try repo("Projects/api")

        let found = await scan()

        XCTAssertEqual(names(found), ["Projects", "loose-repo"])
        XCTAssertFalse(found.contains { $0.path.standardizedFileURL == home.standardizedFileURL })
    }

    func testPlacesThatNeverHoldProjectsAreNotEntered() async throws {
        try repo("Library/Application Support/thing")
        try repo(".Trash/old")
        try repo("Projects/web/node_modules/dep")
        try repo(".cache/tool")
        try repo("Projects/real")

        let found = await scan()

        XCTAssertEqual(names(found), ["Projects"])
        XCTAssertEqual(found.first?.repoCount, 1)
    }

    func testARepositoryIsNeverEnteredSoItsNestedReposAreNotCounted() async throws {
        try repo("Projects/mono")
        try repo("Projects/mono/vendor-copy")

        let found = await scan()

        XCTAssertEqual(found.first?.repoCount, 1)
    }

    func testTheDepthLimitStopsTheWalk() async throws {
        try repo("a/b/c/d/e/f/deep")

        let shallow = await scan(maxDepth: 3)

        XCTAssertTrue(shallow.isEmpty)
    }

    func testALinkedWorktreeCountsAsItsMainRepositoryNotAsANewOne() async throws {
        try repo("Projects/main")
        let linked = home.appendingPathComponent("Projects/main-wt")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try "gitdir: \(home.path)/Projects/main/.git/worktrees/wt\n"
            .write(to: linked.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let found = await scan()

        XCTAssertEqual(found.first?.repoCount, 1)
    }

    func testProgressIsReportedWhileWalking() async throws {
        try repo("Projects/a")
        try repo("Projects/b")
        var sawProgress = false
        for await event in SystemScanner(maxDepth: 5).scan(home: home) {
            if case .progress(_, let repos) = event, repos > 0 { sawProgress = true }
        }
        XCTAssertTrue(sawProgress)
    }

    func testCancellingTheConsumerStopsTheScanEarly() async throws {
        for index in 0..<150 { try repo("Projects/r\(index)") }
        let root: URL = home
        let task = Task { () -> Int in
            var events = 0
            for await _ in SystemScanner(maxDepth: 5).scan(home: root) {
                events += 1
                if Task.isCancelled { break }
            }
            return events
        }
        task.cancel()
        let events = await task.value
        XCTAssertLessThan(events, 150 + 10, "it stopped instead of reporting every repository")
    }

    func testSuggestedFoldersListOnlyThoseThatExistWithTheirRepoCount() async throws {
        try repo("Developer/a")
        try repo("Developer/b")
        try folder("Code")
        try folder("Documents/GitHub")
        try repo("Documents/GitHub/x")

        let suggestions = await FolderSuggestions.find(home: home)

        XCTAssertEqual(
            suggestions.map { $0.path.path.replacingOccurrences(of: home.path + "/", with: "") },
            ["Developer", "Code", "Documents/GitHub"])
        XCTAssertEqual(suggestions.map(\.repoCount), [2, 0, 1])
        XCTAssertEqual(suggestions.map(\.hasRepos), [true, false, true])
    }
}
