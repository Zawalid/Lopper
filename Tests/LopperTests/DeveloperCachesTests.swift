import XCTest
@testable import Lopper

private struct TrashInFolder: TrashProvider {
    let folder: URL

    func moveToTrash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

final class DeveloperCachesTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    private func make(_ relative: String, size: Int) throws {
        let url = home.appendingPathComponent(relative).appendingPathComponent("blob.bin")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try String(repeating: "x", count: size).write(to: url, atomically: true, encoding: .utf8)
    }

    private func cleaner() -> (ArtifactCleaner, UndoLog) {
        let log = UndoLog(url: home.appendingPathComponent("undo-log.jsonl"))
        let trash = TrashInFolder(folder: home.appendingPathComponent(".Trash"))
        return (ArtifactCleaner(undoLog: log, trash: trash, home: home), log)
    }

    func testScanFindsOnlyExistingNonEmptyCachesBiggestFirst() async throws {
        try make("Library/Developer/Xcode/DerivedData", size: 60_000)
        try make(".npm/_cacache", size: 20_000)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Caches/Homebrew"), withIntermediateDirectories: true)

        let caches = await DeveloperCaches.scan(home: home)

        XCTAssertEqual(caches.map(\.name), ["Xcode build data", "npm cache"])
        XCTAssertGreaterThan(caches[0].bytes, caches[1].bytes)
        XCTAssertTrue(caches.allSatisfy { $0.location == .developerCache && $0.removal.isOffered })
        XCTAssertTrue(caches.allSatisfy { $0.path.path.hasPrefix(home.path) })
    }

    func testTheCatalogStaysInsideTheHomeFolder() {
        for entry in DeveloperCaches.catalog(home: home) {
            XCTAssertTrue(entry.path.standardizedFileURL.path.hasPrefix(home.path + "/"), entry.name)
            XCTAssertFalse(entry.path.path.contains(".."), entry.name)
        }
    }

    func testClearingACacheMovesItToTheTrashAndRecordsIt() async throws {
        try make(".npm/_cacache", size: 10_000)
        let found = await DeveloperCaches.scan(home: home)
        let cache = try XCTUnwrap(found.first)
        let (cleaner, log) = cleaner()

        let outcome = await cleaner.clear(cache, names: [])

        guard case .removed(let record) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(record.trashedPath)))
        XCTAssertEqual(record.action, .trashFolder)
        XCTAssertEqual(record.repoPath, "/Developer caches")
        XCTAssertEqual(record.bytes, cache.bytes)
        let logged = await log.all()
        XCTAssertEqual(logged.first?.status, .completed)
    }

    func testAPathThatIsNotInTheCatalogIsRefused() async throws {
        let stray = home.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        let forged = DiskArtifact(
            path: stray, name: "Documents", kind: .cache, bytes: 1, newestModification: nil,
            projectDirectory: home, checkoutRoot: home, repoRoot: URL(fileURLWithPath: "/Developer caches"),
            location: .developerCache, removal: .offered(regenerate: "never"))
        let (cleaner, _) = cleaner()

        let outcome = await cleaner.clear(forged, names: [])

        guard case .skipped = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
    }

    func testACacheThatBecameASymlinkIsNeverFollowed() async throws {
        try make(".npm/_cacache", size: 1_000)
        let found = await DeveloperCaches.scan(home: home)
        let cache = try XCTUnwrap(found.first)
        let precious = home.appendingPathComponent("precious")
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: cache.path)
        try FileManager.default.createSymbolicLink(at: cache.path, withDestinationURL: precious)
        let (cleaner, _) = cleaner()

        let outcome = await cleaner.clear(cache, names: [])

        guard case .skipped = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.path))
    }

    func testVolumeSpaceReportsTotalAndFreeForARealFolder() throws {
        let space = try XCTUnwrap(VolumeSpace.read(at: home))

        XCTAssertGreaterThan(space.total, 0)
        XCTAssertGreaterThan(space.available, 0)
        XCTAssertLessThanOrEqual(space.available, space.total)
        XCTAssertEqual(space.used, space.total - space.available)
    }
}
