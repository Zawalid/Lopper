import XCTest
@testable import Lopper

final class OverrideBehaviourTests: XCTestCase {
    private func mergedBranch(_ repo: TestRepo, _ name: String) throws {
        try repo.git("checkout", "-b", name)
        try repo.commit("work on \(name)", files: ["\(name.replacingOccurrences(of: "/", with: "-")).txt": name])
        try repo.git("checkout", "main")
        try repo.git("merge", "--no-ff", "-m", "merge \(name)", name)
    }

    func testPerRepositoryDefaultBranchOverrideMakesMergedBranchesSafe() async throws {
        let repo = try TestRepo()
        try repo.git("branch", "-m", "main", "trunk")
        try repo.commit("base", files: ["a.txt": "a"])
        try repo.git("checkout", "-b", "feature")
        try repo.commit("work", files: ["f.txt": "f"])
        try repo.git("checkout", "trunk")
        try repo.git("merge", "--no-ff", "-m", "merge feature", "feature")

        let without = try await RepoInspector().inspect(repoRoot: repo.root)
        XCTAssertNil(without.repo.defaultBranch)
        XCTAssertEqual(without.branches.first { $0.name == "feature" }?.verdict.kind, .review)

        var settings = Settings(roots: [repo.sandbox])
        settings.repos[repo.root.path] = RepoOverrides(defaultBranch: "trunk")
        let with = try await RepoInspector(settings: settings).inspect(repoRoot: repo.root)

        XCTAssertEqual(with.repo.defaultBranch, "trunk")
        XCTAssertEqual(with.branches.first { $0.name == "feature" }?.verdict.kind, .safe)
        XCTAssertEqual(with.branches.first { $0.name == "trunk" }?.verdict.kind, .protected)
    }

    func testPerRepositoryProtectedPatternsReplaceTheGlobalOnesForThatRepositoryOnly() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: ["a.txt": "a"])
        try mergedBranch(repo, "release/1")
        try mergedBranch(repo, "keepme")
        var settings = Settings(roots: [repo.sandbox])
        settings.protectedPatterns = ["main", "release/*"]

        let global = try await RepoInspector(settings: settings).inspect(repoRoot: repo.root)
        XCTAssertEqual(global.branches.first { $0.name == "release/1" }?.verdict.kind, .protected)
        XCTAssertEqual(global.branches.first { $0.name == "keepme" }?.verdict.kind, .safe)

        settings.repos[repo.root.path] = RepoOverrides(protectedPatterns: ["keepme"])
        let overridden = try await RepoInspector(settings: settings).inspect(repoRoot: repo.root)

        XCTAssertEqual(overridden.branches.first { $0.name == "release/1" }?.verdict.kind, .safe)
        XCTAssertEqual(overridden.branches.first { $0.name == "keepme" }?.verdict.kind, .protected)
        XCTAssertEqual(overridden.branches.first { $0.name == "main" }?.verdict.kind, .protected,
                       "the default branch is protected whatever the patterns say")
    }

    func testIgnoredRepositoriesNeverAppearInScanResults() async throws {
        let fixture = try TestRepo()
        let base = fixture.sandbox.appendingPathComponent("code")
        for name in ["keep", "hide"] {
            try TestRepo.makeStandaloneRepo(at: base.appendingPathComponent(name))
        }
        var settings = Settings(roots: [base])
        settings.repos[base.appendingPathComponent("hide").canonicalized.path] = RepoOverrides(isIgnored: true)
        let service = ScanService(inspector: RepoInspector(settings: settings))

        let scanned = await service.scan(roots: [base], maxDepth: 3)
        XCTAssertEqual(scanned.map { $0.repoRoot.lastPathComponent }, ["keep"])

        var streamed: [String] = []
        var discovered = -1
        for await event in service.scanStream(roots: [base], maxDepth: 3) {
            switch event {
            case .discovered(let count): discovered = count
            case .result(let result): streamed.append(result.repoRoot.lastPathComponent)
            }
        }
        XCTAssertEqual(streamed, ["keep"])
        XCTAssertEqual(discovered, 1, "the progress total must not count ignored repositories")
    }

    func testExcludePatternsKeepMatchingDirectoriesOutOfDiscovery() throws {
        let fixture = try TestRepo()
        let base = fixture.sandbox.appendingPathComponent("code")
        for name in ["app", "legacy-one", "legacy-two", "tools/legacy-three", "tools/keeper"] {
            try TestRepo.makeStandaloneRepo(at: base.appendingPathComponent(name))
        }

        let found = RepoScanner(excludePatterns: ["legacy-*"]).findRepos(in: [base], maxDepth: 4)

        XCTAssertEqual(
            found.map { $0.path.replacingOccurrences(of: base.canonicalized.path, with: "") },
            ["/app", "/tools/keeper"])
    }

    func testEnabledFoldersContributeTheirExcludePatterns() {
        let settings = Settings(folders: [
            FolderSetting(path: URL(fileURLWithPath: "/a"), excludePatterns: ["legacy-*", "vendor"]),
            FolderSetting(path: URL(fileURLWithPath: "/b"), isEnabled: false, excludePatterns: ["ignored-when-paused"]),
            FolderSetting(path: URL(fileURLWithPath: "/c"), excludePatterns: ["vendor"]),
        ])

        XCTAssertEqual(settings.excludePatterns, ["legacy-*", "vendor"])
    }
}
