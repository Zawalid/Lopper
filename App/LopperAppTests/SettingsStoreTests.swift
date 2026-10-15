import XCTest
import Lopper
@testable import LopperApp

private final class WriteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Settings] = []
    func append(_ settings: Settings) { lock.lock(); entries.append(settings); lock.unlock() }
    var all: [Settings] { lock.lock(); defer { lock.unlock() }; return entries }
}

final class SettingsStoreTests: XCTestCase {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-store-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    func testRapidChangesAreCoalescedIntoOneWriteWithTheLastValue() async throws {
        let log = WriteLog()
        let store = SettingsStore(url: temporaryFile(), debounce: .milliseconds(60)) { settings, _ in
            log.append(settings)
        }

        for depth in 1...10 {
            var settings = Settings()
            settings.scanDepth = depth
            store.scheduleSave(settings)
        }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(log.all.count, 1)
        XCTAssertEqual(log.all.last?.scanDepth, 10)
    }

    func testFlushWritesPendingChangesImmediately() throws {
        let log = WriteLog()
        let store = SettingsStore(url: temporaryFile(), debounce: .seconds(30)) { settings, _ in
            log.append(settings)
        }
        var settings = Settings()
        settings.scanDepth = 6
        store.scheduleSave(settings)
        XCTAssertEqual(log.all.count, 0, "nothing is written before the debounce elapses")

        store.flush()

        XCTAssertEqual(log.all.map(\.scanDepth), [6])
        store.flush()
        XCTAssertEqual(log.all.count, 1, "flushing twice must not write twice")
    }

    func testCorruptFileIsReportedWithABackupAndDefaultsAreUsed() throws {
        let file = temporaryFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: file)

        let result = SettingsStore(url: file).load()

        guard case .recoveredFromCorruption(let backup) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "not json at all")
        XCTAssertEqual(result.settings, Settings())
    }
}
