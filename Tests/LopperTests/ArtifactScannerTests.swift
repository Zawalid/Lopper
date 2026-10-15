import XCTest
@testable import Lopper

final class ArtifactScannerTests: XCTestCase {
    private let names: Set<String> = ["node_modules", ".next", "dist", "target", ".cache"]

    private func repo(gitignore: String = "node_modules\n.next\ndist\ntarget\n.cache\n") throws -> TestRepo {
        let repo = try TestRepo()
        try repo.commit("base", files: [".gitignore": gitignore, "package.json": "{}\n", "package-lock.json": "{}\n"])
        return repo
    }

    private func bytes(_ count: Int) -> String { String(repeating: "x", count: count) }

    private func scan(_ repo: TestRepo, root: URL? = nil, location: ArtifactLocation = .mainCheckout) async -> [DiskArtifact] {
        await ArtifactScanner().scan(root: root ?? repo.root, repoRoot: repo.root, names: names, location: location)
    }

    private func write(_ repo: TestRepo, _ path: String, _ size: Int, in base: URL? = nil) throws {
        let url = (base ?? repo.root).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes(size).write(to: url, atomically: true, encoding: .utf8)
    }

    func testFindsIgnoredBuildFoldersWithTheirSizeAndHowTheyComeBack() async throws {
        let repo = try repo()
        try write(repo, "node_modules/left-pad/index.js", 50_000)
        try write(repo, "dist/app.js", 10_000)

        let found = await scan(repo)

        let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["node_modules", "dist"])
        XCTAssertGreaterThanOrEqual(byName["node_modules"]?.bytes ?? 0, 50_000)
        XCTAssertEqual(byName["node_modules"]?.removal, .offered(regenerate: "npm ci"))
        XCTAssertEqual(byName["dist"]?.removal, .offered(regenerate: "your build script"))
        XCTAssertEqual(byName["dist"]?.kind, .buildOutput)
        XCTAssertEqual(byName["node_modules"]?.checkoutRoot, repo.root)
    }

    func testAFolderGitDoesNotIgnoreIsNeverOffered() async throws {
        // `dist` is committed on purpose here, so it is source, not output.
        let repo = try repo(gitignore: "node_modules\n")
        try write(repo, "dist/app.js", 10_000)
        try repo.git("add", "-A")
        try repo.git("commit", "-m", "commit dist on purpose")
        try write(repo, "node_modules/a/index.js", 1_000)

        let found = await scan(repo)

        XCTAssertEqual(found.map(\.name), ["node_modules"])
    }

    func testAnUnignoredButUntrackedFolderIsNotOfferedEither() async throws {
        let repo = try repo(gitignore: "node_modules\n")
        try write(repo, "dist/app.js", 10_000)   // exists, untracked, not ignored

        let found = await scan(repo)

        XCTAssertTrue(found.isEmpty, "git must say it is ignored; a matching name is not enough")
    }

    func testMonorepoPackagesAreFoundAndNestedModulesAreNotCountedTwice() async throws {
        let repo = try repo()
        try write(repo, "packages/web/node_modules/react/index.js", 20_000)
        try write(repo, "packages/web/node_modules/react/node_modules/inner/index.js", 5_000)
        try write(repo, "packages/api/node_modules/express/index.js", 30_000)
        try write(repo, "packages/web/package.json", 2)
        try write(repo, "packages/web/package-lock.json", 2)

        let found = await scan(repo)

        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.map { $0.path.pathComponents.suffix(3).joined(separator: "/") }),
                       ["packages/web/node_modules", "packages/api/node_modules"].reduce(into: Set<String>()) { $0.insert($1) })
    }

    func testTheLockfileIsLookedForBesideTheFolderNotOnlyAtTheRoot() async throws {
        let repo = try repo()   // a lockfile exists at the root
        try write(repo, "packages/lonely/node_modules/a/index.js", 1_000)   // but not in this package

        let found = await scan(repo)

        guard case .blocked = found.first?.removal else { return XCTFail("\(String(describing: found.first?.removal))") }
    }

    func testAWorktreeIsScannedFromItsOwnFolder() async throws {
        let repo = try repo()
        let worktree = repo.sandbox.appendingPathComponent("wt-feature")
        try repo.git("worktree", "add", "-b", "feature", worktree.path, "main")
        try write(repo, "node_modules/main-only/index.js", 5_000)
        try write(repo, ".next/cache/blob", 70_000, in: worktree)

        let inMain = await scan(repo)
        let inWorktree = await scan(repo, root: worktree, location: .worktree(branch: "feature"))

        XCTAssertEqual(inMain.map(\.name), ["node_modules"])
        XCTAssertEqual(inWorktree.map(\.name), [".next"])
        XCTAssertEqual(inWorktree.first?.location, .worktree(branch: "feature"))
        XCTAssertEqual(inWorktree.first?.checkoutRoot, worktree)
        XCTAssertEqual(inWorktree.first?.repoRoot, repo.root)
    }

    func testAFolderInsideAnIgnoredDirectoryIsNotReportedTwice() async throws {
        let repo = try repo(gitignore: "node_modules\n.claude/\n")
        try write(repo, ".claude/worktrees/x/node_modules/a/index.js", 9_000)

        let found = await scan(repo)

        XCTAssertTrue(found.isEmpty, "that belongs to another checkout and is reported there")
    }

    func testSymlinksAreNeverFollowedOrOffered() async throws {
        let repo = try repo()
        let target = repo.sandbox.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try bytes(90_000).write(to: target.appendingPathComponent("big"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: repo.root.appendingPathComponent("node_modules"), withDestinationURL: target)

        let found = await scan(repo)

        XCTAssertTrue(found.isEmpty)
    }

    func testNewestModificationIsTheNewestFileInsideTheFolder() async throws {
        let repo = try repo()
        try write(repo, "node_modules/a/old.js", 100)
        try write(repo, "node_modules/a/new.js", 100)
        let old = Date().addingTimeInterval(-40 * 86_400)
        try FileManager.default.setAttributes(
            [.modificationDate: old], ofItemAtPath: repo.root.appendingPathComponent("node_modules/a/old.js").path)

        let found = await scan(repo)

        let newest = try XCTUnwrap(found.first?.newestModification)
        XCTAssertLessThan(abs(newest.timeIntervalSinceNow), 120, "the newer file wins")
    }

    func testARepositoryWithNothingIgnoredHasNoArtifacts() async throws {
        let repo = try repo()

        let found = await scan(repo)

        XCTAssertTrue(found.isEmpty)
    }

    func testAWorkspacePackageUsesTheLockfileAtTheWorkspaceRoot() async throws {
        let repo = try repo()
        try write(repo, "package.json", 40)
        try "{\"workspaces\": [\"packages/*\"]}\n".write(
            to: repo.root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try write(repo, "packages/web/node_modules/react/index.js", 20_000)

        let found = await scan(repo)

        XCTAssertEqual(found.first?.removal, .offered(regenerate: "npm ci"))
    }

    func testAPnpmWorkspaceRootCountsToo() async throws {
        let repo = try repo()
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("package-lock.json"))
        try write(repo, "pnpm-lock.yaml", 10)
        try write(repo, "pnpm-workspace.yaml", 10)
        try write(repo, "apps/site/node_modules/next/index.js", 20_000)

        let found = await scan(repo)

        XCTAssertEqual(found.first?.removal, .offered(regenerate: "pnpm install"))
    }
}
