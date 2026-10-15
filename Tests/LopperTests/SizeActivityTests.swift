import XCTest
@testable import Lopper

final class SizeActivityTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ url: URL, modified: Date) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    func testNewestModificationIgnoresDisposableFoldersAndGit() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let mid = Date(timeIntervalSince1970: 1_700_100_000)
        let newest = Date(timeIntervalSince1970: 1_700_900_000)
        try write(dir.appendingPathComponent("src/a.swift"), modified: old)
        try write(dir.appendingPathComponent("src/b.swift"), modified: mid)
        try write(dir.appendingPathComponent("node_modules/pkg/i.js"), modified: newest)
        try write(dir.appendingPathComponent(".git"), modified: newest)

        let usage = await SizeCalculator.measure(dir, disposableNames: ["node_modules"])

        XCTAssertEqual(usage.newestModification, mid)
    }

    func testEmptyFolderHasNoActivity() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let usage = await SizeCalculator.measure(dir, disposableNames: [])
        XCTAssertNil(usage.newestModification)
        XCTAssertEqual(usage, DiskUsage(total: 0, disposable: 0))
    }

    func testNestedFoldersToSkipAreNotCounted() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let newest = Date(timeIntervalSince1970: 1_700_900_000)
        try write(dir.appendingPathComponent("src/a.swift"), modified: old)
        // An agent worktree that lives inside the main folder: its files belong to that worktree, not to this one.
        try write(dir.appendingPathComponent(".claude/worktrees/x/big.swift"), modified: newest)
        let nested = dir.appendingPathComponent(".claude/worktrees/x")

        let usage = await SizeCalculator.measure(dir, disposableNames: [], excluding: [nested])

        XCTAssertEqual(usage.newestModification, old)
        let whole = await SizeCalculator.measure(dir, disposableNames: [])
        XCTAssertGreaterThan(whole.total, usage.total)
    }
}
