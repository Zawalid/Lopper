import XCTest
@testable import Lopper

final class SettingsLoaderTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("settings.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-loader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0 != "settings.json" }
            .sorted()
    }

    func testMissingFileGivesDefaultsAndWritesNothing() throws {
        let result = SettingsLoader.load(from: file)

        XCTAssertEqual(result.outcome, .created)
        XCTAssertEqual(result.settings, Settings())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testCurrentFileLoadsWithoutBackups() throws {
        var settings = Settings(roots: [URL(fileURLWithPath: "/code")])
        settings.scanDepth = 6
        try settings.save(to: file)

        let result = SettingsLoader.load(from: file)

        XCTAssertEqual(result.outcome, .loaded)
        XCTAssertEqual(result.settings, settings)
        XCTAssertEqual(try backups(), [])
    }

    func testVersion1FileMigratesAndTheOriginalIsKeptByteForByte() throws {
        let original = Data(SettingsV2Tests.version1.utf8)
        try original.write(to: file)

        let result = SettingsLoader.load(from: file)

        guard case .migrated(let backup) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(backup.lastPathComponent, "settings.json.v1-backup")
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try Data(contentsOf: file), original, "loading must not rewrite the file")
        XCTAssertEqual(result.settings.folders.map(\.path.path), ["/code", "/work/projects"])
    }

    func testTheFirstBackupIsNeverOverwritten() throws {
        let original = Data(SettingsV2Tests.version1.utf8)
        try original.write(to: file)
        _ = SettingsLoader.load(from: file)
        try Data(SettingsV2Tests.version1.replacingOccurrences(of: "\"scanDepth\" : 3", with: "\"scanDepth\" : 7").utf8)
            .write(to: file)

        _ = SettingsLoader.load(from: file)

        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("settings.json.v1-backup")), original)
    }

    func testAfterTheFirstSaveTheFileIsCurrentAndNoNewBackupAppears() throws {
        try Data(SettingsV2Tests.version1.utf8).write(to: file)
        let first = SettingsLoader.load(from: file)
        try first.settings.save(to: file)

        let second = SettingsLoader.load(from: file)

        XCTAssertEqual(second.outcome, .loaded)
        XCTAssertEqual(try backups(), ["settings.json.v1-backup"])
    }

    func testGarbageAndTruncatedFilesAreCopiedAsideAndDefaultsUsed() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [Data] = [
            Data([0xff, 0xfe, 0x00, 0x01, 0x02]),
            Data(#"{ "schemaVersion" : 2, "folders" : [ { "path" : "file:\/\/\/code\/" }"#.utf8),
        ]
        for original in cases {
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try original.write(to: file)

            let result = SettingsLoader.load(from: file, now: now)

            guard case .recoveredFromCorruption(let backup) = result.outcome else {
                return XCTFail("\(result.outcome)")
            }
            XCTAssertTrue(backup.lastPathComponent.hasPrefix("settings.json.broken-"))
            XCTAssertEqual(try Data(contentsOf: backup), original)
            XCTAssertEqual(result.settings, Settings())

            // Saving the defaults afterwards must not touch the copy.
            try result.settings.save(to: file)
            XCTAssertEqual(try Data(contentsOf: backup), original)
        }
    }

    func testNewerVersionIsLoadedKeepsUnknownKeysAndIsBackedUp() throws {
        let json = """
        { "schemaVersion" : 99, "scanDepth" : 8, "futureThing" : { "enabled" : true } }
        """
        try Data(json.utf8).write(to: file)

        let result = SettingsLoader.load(from: file)

        guard case .newerVersion(let backup) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(backup.lastPathComponent, "settings.json.v99-backup")
        XCTAssertEqual(result.settings.scanDepth, 8)
        XCTAssertEqual(result.settings.schemaVersion, 99, "an older build must not claim to have rewritten it")
        XCTAssertEqual(result.settings.unknownKeys["futureThing"], .object(["enabled": .bool(true)]))
    }

    func testConvenienceLoadStillReturnsJustTheSettings() throws {
        try Settings(roots: [URL(fileURLWithPath: "/code")]).save(to: file)
        XCTAssertEqual(Settings.load(from: file).roots.map(\.path), ["/code"])
    }
}
