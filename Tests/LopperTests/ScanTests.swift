import XCTest
@testable import Lopper

final class ScanTests: XCTestCase {
    func testFindsReposRespectsDepthAndSkipsNoise() throws {
        let fixture = try TestRepo()
        let base = fixture.sandbox.appendingPathComponent("code")
        try TestRepo.makeStandaloneRepo(at: base.appendingPathComponent("a"))
        try TestRepo.makeStandaloneRepo(at: base.appendingPathComponent("group/b"))
        try TestRepo.makeStandaloneRepo(at: base.appendingPathComponent("group/node_modules/c"))
        try TestRepo.makeStandaloneRepo(at: base.appendingPathComponent("l1/l2/l3/l4/l5/too-deep"))

        let found = RepoScanner().findRepos(in: [base], maxDepth: 4)
        XCTAssertEqual(
            found.map { $0.path.replacingOccurrences(of: base.path, with: "") },
            ["/a", "/group/b"])
    }

    func testLinkedWorktreeResolvesToItsMainRepoOnce() throws {
        let fixture = try TestRepo()
        try fixture.commit("base", files: ["a": "a"])
        let wt = fixture.sandbox.appendingPathComponent("code/wt")
        try FileManager.default.createDirectory(
            at: wt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture.git("worktree", "add", "-b", "wt", wt.path)

        let found = RepoScanner().findRepos(in: [fixture.sandbox], maxDepth: 4)
        XCTAssertEqual(found.map(\.path), [fixture.root.path])
    }

    func testSymlinkedRootReportsCanonicalRepoPaths() throws {
        let fixture = try TestRepo()
        let real = fixture.sandbox.appendingPathComponent("real")
        try TestRepo.makeStandaloneRepo(at: real.appendingPathComponent("app"))
        let link = fixture.sandbox.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let found = RepoScanner().findRepos(in: [link], maxDepth: 4)
        XCTAssertEqual(found.map(\.path), [real.appendingPathComponent("app").path])
    }

    func testSubmoduleIsNotTreatedAsRepo() throws {
        let fixture = try TestRepo()
        let base = fixture.sandbox.appendingPathComponent("code")
        let sub = base.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "gitdir: ../.git/modules/sub\n".write(
            to: sub.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        XCTAssertTrue(RepoScanner().findRepos(in: [base], maxDepth: 4).isEmpty)
    }

    func testScanServiceIsolatesBrokenRepos() async throws {
        let fixture = try TestRepo()
        let base = fixture.sandbox.appendingPathComponent("code")
        try TestRepo.makeStandaloneRepo(at: base.appendingPathComponent("good1"))
        try TestRepo.makeStandaloneRepo(at: base.appendingPathComponent("good2"))
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("broken/.git"), withIntermediateDirectories: true)

        let service = ScanService(inspector: RepoInspector())
        let results = await service.scan(roots: [base], maxDepth: 3)
        XCTAssertEqual(results.count, 3)
        var snapshots = 0
        var failures = 0
        for result in results {
            switch result {
            case .snapshot: snapshots += 1
            case .failure(let root, _):
                failures += 1
                XCTAssertEqual(root.lastPathComponent, "broken")
            }
        }
        XCTAssertEqual(snapshots, 2)
        XCTAssertEqual(failures, 1)
    }

    func testRepoGateCancellationReleasesTheCallerPromptly() async throws {
        let gate = RepoGate()
        let started = ContinuousClock.now
        let task = Task {
            try await gate.run(key: "r") { try await Task.sleep(for: .seconds(5)) }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    func testRepoGateRunsSameKeyWorkInOrder() async throws {
        let gate = RepoGate()
        let log = LockedLog()
        async let first: Void = gate.run(key: "r") {
            await log.append("a-start")
            try await Task.sleep(for: .milliseconds(100))
            await log.append("a-end")
        }
        try await Task.sleep(for: .milliseconds(20))
        async let second: Void = gate.run(key: "r") { await log.append("b") }
        _ = try await (first, second)
        let entries = await log.entries
        XCTAssertEqual(entries, ["a-start", "a-end", "b"])
    }
}

private actor LockedLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}
