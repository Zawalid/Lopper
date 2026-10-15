import XCTest
@testable import Lopper

final class DiskAndGhTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-disk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testMeasureSplitsDisposableFromTotal() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let modules = dir.appendingPathComponent("node_modules/pkg")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100_000).write(to: modules.appendingPathComponent("big.bin"))
        try Data(repeating: 2, count: 10_000).write(to: dir.appendingPathComponent("src.bin"))

        let usage = await SizeCalculator.measure(dir, disposableNames: ["node_modules"])

        // Allocated size rounds up to filesystem blocks, so assert ranges rather than exact bytes.
        XCTAssertGreaterThanOrEqual(usage.disposable, 100_000)
        XCTAssertLessThan(usage.disposable, 120_000)
        XCTAssertGreaterThanOrEqual(usage.total, usage.disposable + 10_000)
    }

    func testMeasureOfMissingDirectoryIsZero() async {
        let usage = await SizeCalculator.measure(
            URL(fileURLWithPath: "/no/such/dir-\(UUID().uuidString)"), disposableNames: [])
        XCTAssertEqual(usage, DiskUsage(total: 0, disposable: 0))
    }

    func testDecodeGhJson() throws {
        let json = #"[{"number":482,"headRefName":"feat/login","headRefOid":"abc123","baseRefName":"main"},{"number":7,"headRefName":"fix/x","headRefOid":"def456","baseRefName":"develop"}]"#
        let prs = try GhCliProvider.decode(json)
        XCTAssertEqual(prs, [
            MergedPR(number: 482, headBranch: "feat/login", headSHA: "abc123", baseBranch: "main"),
            MergedPR(number: 7, headBranch: "fix/x", headSHA: "def456", baseBranch: "develop"),
        ])
    }

    private func stubGh(_ script: String) throws -> URL {
        let dir = try tempDirectory()
        let url = dir.appendingPathComponent("gh")
        try ("#!/bin/sh\n" + script + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testProviderParsesStubOutput() async throws {
        let gh = try stubGh(#"echo '[{"number":3,"headRefName":"b","headRefOid":"s","baseRefName":"main"}]'"#)
        let provider = try XCTUnwrap(GhCliProvider(executable: gh))
        let prs = try await provider.mergedPullRequests(in: FileManager.default.temporaryDirectory)
        XCTAssertEqual(prs, [MergedPR(number: 3, headBranch: "b", headSHA: "s", baseBranch: "main")])
    }

    func testProviderThrowsWhenGhFails() async throws {
        let gh = try stubGh("echo 'not logged in' >&2; exit 4")
        let provider = try XCTUnwrap(GhCliProvider(executable: gh))
        do {
            _ = try await provider.mergedPullRequests(in: FileManager.default.temporaryDirectory)
            XCTFail("expected failure")
        } catch let CommandError.failed(_, exitCode, stderr) {
            XCTAssertEqual(exitCode, 4)
            XCTAssertTrue(stderr.contains("not logged in"))
        }
    }

    func testProviderIsNilWithoutExecutable() {
        XCTAssertNil(GhCliProvider(executable: nil))
    }
}
