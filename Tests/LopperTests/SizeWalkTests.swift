import XCTest
@testable import Lopper

/// The size walk visits every file of every project on a scan, so what it counts must stay exact while it is made cheap,
/// and it must stop when a newer scan makes its answer worthless.
final class SizeWalkTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lopper-walk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    /// The definition the walk must keep: a file is disposable when any part of its path below the folder matches.
    private func reference(_ directory: URL, disposable: Set<String>) -> (total: Int64, disposable: Int64) {
        var total: Int64 = 0
        var cheap: Int64 = 0
        let base = directory.standardizedFileURL.pathComponents.count
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        for case let url as URL in FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys)! {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                let size = values.totalFileAllocatedSize else { continue }
            total += Int64(size)
            if url.standardizedFileURL.pathComponents.dropFirst(base).contains(where: { GitParsers.matchesDisposable($0, disposable) }) {
                cheap += Int64(size)
            }
        }
        return (total, cheap)
    }

    func testDisposableBytesMatchTheDefinitionOnAnAwkwardTree() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for path in [
            "src/a.swift", "src/b.swift",
            "node_modules/pkg/index.js", "node_modules/pkg/deep/more/x.js", "node_modules/z.js",
            "aaa/keep.txt", "zzz/keep.txt",                      // siblings either side of a disposable folder
            "app/.next/cache/blob", "app/after.txt",             // a disposable folder, then a file at the same level
            "lib/tsconfig.tsbuildinfo", "lib/real.ts",           // a disposable file by pattern
            ".DS_Store", "a/b/c/.DS_Store",
            "node_modules_not/ok.txt",                           // a name that only starts like a disposable one
        ] { try write(dir.appendingPathComponent(path), bytes: 5_000) }
        let names: Set<String> = ["node_modules", ".next", "*.tsbuildinfo", ".DS_Store"]

        let usage = await SizeCalculator.measure(dir, disposableNames: names)

        let expected = reference(dir, disposable: names)
        XCTAssertEqual(usage.total, expected.total)
        XCTAssertEqual(usage.disposable, expected.disposable, "the walk and the plain definition disagree")
        XCTAssertGreaterThan(usage.disposable, 0)
        XCTAssertLessThan(usage.disposable, usage.total)
    }

    func testAWalkThatIsToldToStopReturnsEarlyWithLessThanTheWholeTree() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<900 { try write(dir.appendingPathComponent("f/\(index).txt"), bytes: 100) }
        let whole = SizeCalculator.measureSync(dir, disposableNames: [])

        let stopped = SizeCalculator.measureSync(dir, disposableNames: [], shouldStop: { true })

        XCTAssertLessThan(stopped.total, whole.total, "a stopped walk must not finish the tree")
    }

    func testCancellingTheTaskStopsTheWalkBeforeItFinishesTheTree() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for index in 0..<4_000 { try write(dir.appendingPathComponent("d\(index % 40)/\(index).txt"), bytes: 100) }
        let whole = await SizeCalculator.measure(dir, disposableNames: [])

        let task = Task { await SizeCalculator.measure(dir, disposableNames: []) }
        task.cancel()
        let partial = await task.value

        XCTAssertLessThan(partial.total, whole.total, "the cancelled walk should have stopped early")
    }

    func testAFewFoldersAreMeasuredAtATime() {
        XCTAssertLessThanOrEqual(SizeCalculator.concurrentMeasurements, 2)
        XCTAssertGreaterThanOrEqual(SizeCalculator.concurrentMeasurements, 1)
    }
}
