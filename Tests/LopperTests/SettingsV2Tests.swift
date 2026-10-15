import XCTest
@testable import Lopper

final class SettingsV2Tests: XCTestCase {
    /// Frozen shape of a version 1 file as written by earlier builds (no schemaVersion, `roots` as URLs,
    /// two per-repository dictionaries).
    static let version1 = """
    {
      "defaultBranchOverrides" : { "/code/api" : "trunk" },
      "disposableNames" : [ "node_modules", ".DS_Store" ],
      "protectedPatterns" : [ "main", "release\\/*" ],
      "repoDisposableNames" : { "/code/api" : [ ".env.test" ], "/code/apps" : [ "media" ] },
      "roots" : [ "file:\\/\\/\\/code\\/", "file:\\/\\/\\/work\\/projects\\/" ],
      "scanDepth" : 3,
      "staleDays" : 21,
      "trashRetentionDays" : 14
    }
    """

    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    func testVersion1FileMigratesToFoldersAndRepoOverrides() throws {
        let settings = try decode(Self.version1)

        XCTAssertEqual(settings.schemaVersion, Settings.currentSchemaVersion)
        XCTAssertEqual(settings.folders.map(\.path.path), ["/code", "/work/projects"])
        XCTAssertTrue(settings.folders.allSatisfy(\.isEnabled))
        XCTAssertEqual(settings.scanDepth, 3)
        XCTAssertEqual(settings.staleDays, 21)
        XCTAssertEqual(settings.trashRetentionDays, 14)
        XCTAssertEqual(settings.protectedPatterns, ["main", "release/*"])
        XCTAssertEqual(settings.repos["/code/api"]?.defaultBranch, "trunk")
        XCTAssertEqual(settings.repos["/code/api"]?.disposableNames, [".env.test"])
        XCTAssertEqual(settings.repos["/code/apps"]?.disposableNames, ["media"])
        XCTAssertNil(settings.repos["/code/apps"]?.defaultBranch)
    }

    func testUnknownKeysSurviveARoundTrip() throws {
        let json = """
        { "schemaVersion" : 2, "scanDepth" : 5, "futureThing" : { "a" : [ 1, 2.5, "x", true, null ] } }
        """
        let settings = try decode(json)

        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let future = try XCTUnwrap(object["futureThing"] as? [String: Any])
        let list = try XCTUnwrap(future["a"] as? [Any])
        XCTAssertEqual(list.count, 5)
        XCTAssertEqual(list[0] as? Int, 1)
        XCTAssertEqual(list[1] as? Double, 2.5)
        XCTAssertEqual(list[2] as? String, "x")
        XCTAssertEqual(list[3] as? Bool, true)
        XCTAssertTrue(list[4] is NSNull)
        XCTAssertEqual(object["scanDepth"] as? Int, 5)
    }

    func testRootsSetterKeepsFlagsOfRemainingFoldersAndDropsRemovedOnes() {
        var settings = Settings(folders: [
            FolderSetting(path: URL(fileURLWithPath: "/code"), isEnabled: false, excludePatterns: ["vendor"]),
            FolderSetting(path: URL(fileURLWithPath: "/work")),
        ])

        settings.roots = [URL(fileURLWithPath: "/code"), URL(fileURLWithPath: "/new")]

        XCTAssertEqual(settings.folders.map(\.path.path), ["/code", "/new"])
        XCTAssertEqual(settings.folders[0].isEnabled, false, "an existing folder keeps its flags")
        XCTAssertEqual(settings.folders[0].excludePatterns, ["vendor"])
        XCTAssertEqual(settings.folders[1].isEnabled, true)
    }

    func testDisabledFoldersAreNotRoots() {
        let settings = Settings(folders: [
            FolderSetting(path: URL(fileURLWithPath: "/code")),
            FolderSetting(path: URL(fileURLWithPath: "/paused"), isEnabled: false),
        ])

        XCTAssertEqual(settings.roots.map(\.path), ["/code"])
    }

    func testPerRepositoryOverridesFallBackToGlobalValues() {
        var settings = Settings(roots: [URL(fileURLWithPath: "/code")])
        settings.protectedPatterns = ["main", "release/*"]
        let api = URL(fileURLWithPath: "/code/api")
        let other = URL(fileURLWithPath: "/code/other")

        XCTAssertNil(settings.defaultBranchOverride(for: api))
        XCTAssertEqual(settings.protectedPatterns(for: api), ["main", "release/*"])
        XCTAssertFalse(settings.isIgnored(api))

        settings.repos[api.path] = RepoOverrides(
            defaultBranch: "trunk", protectedPatterns: ["trunk"], disposableNames: [".env.test"], isIgnored: true)

        XCTAssertEqual(settings.defaultBranchOverride(for: api), "trunk")
        XCTAssertEqual(settings.protectedPatterns(for: api), ["trunk"])
        XCTAssertTrue(settings.isIgnored(api))
        XCTAssertTrue(settings.disposableSet(for: api).contains(".env.test"))
        XCTAssertTrue(settings.disposableSet(for: api).contains("node_modules"))
        // Another repository is unaffected.
        XCTAssertEqual(settings.protectedPatterns(for: other), ["main", "release/*"])
        XCTAssertFalse(settings.disposableSet(for: other).contains(".env.test"))
    }

    func testEncodedFileIsPrettyPrintedWithStableKeyOrder() throws {
        let settings = Settings(roots: [URL(fileURLWithPath: "/code")])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-v2-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try settings.save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(text.contains("\"schemaVersion\" : 2"))
        XCTAssertTrue(text.contains("\n"), "pretty printed")
        let folders = try XCTUnwrap(text.range(of: "\"folders\""))
        let depth = try XCTUnwrap(text.range(of: "\"scanDepth\""))
        XCTAssertLessThan(folders.lowerBound, depth.lowerBound, "keys are sorted so diffs stay small")
        XCTAssertFalse(text.contains("\"roots\""), "the legacy key is no longer written")
    }

    func testLegacyRepoDictionariesStayReadableAndWritableForExistingCallers() {
        var settings = Settings()
        settings.repoDisposableNames["/code/api"] = [".env.test"]
        settings.defaultBranchOverrides["/code/api"] = "trunk"

        XCTAssertEqual(settings.repos["/code/api"]?.disposableNames, [".env.test"])
        XCTAssertEqual(settings.repos["/code/api"]?.defaultBranch, "trunk")
        XCTAssertEqual(settings.repoDisposableNames["/code/api"], [".env.test"])
        XCTAssertEqual(settings.defaultBranchOverrides["/code/api"], "trunk")
    }

    // MARK: Rescan rules

    private func base() -> Settings {
        Settings(folders: [
            FolderSetting(path: URL(fileURLWithPath: "/code")),
            FolderSetting(path: URL(fileURLWithPath: "/paused"), isEnabled: false),
        ])
    }

    func testChangesThatAffectWhatIsFoundOrDecidedRequireARescan() {
        let before = base()
        let changes: [(String, (inout Settings) -> Void)] = [
            ("add a folder", { $0.folders.append(FolderSetting(path: URL(fileURLWithPath: "/new"))) }),
            ("pause a folder", { $0.folders[0].isEnabled = false }),
            ("resume a folder", { $0.folders[1].isEnabled = true }),
            ("exclude pattern", { $0.folders[0].excludePatterns = ["vendor"] }),
            ("scan depth", { $0.scanDepth = 7 }),
            ("protected patterns", { $0.protectedPatterns.append("staging") }),
            ("throwaway names", { $0.disposableNames.append("tmp") }),
            ("repo default branch", { $0.repos["/code/api", default: RepoOverrides()].defaultBranch = "trunk" }),
            ("repo ignored", { $0.repos["/code/api", default: RepoOverrides()].isIgnored = true }),
            ("repo throwaway", { $0.repos["/code/api", default: RepoOverrides()].disposableNames = ["x"] }),
        ]
        for (name, change) in changes {
            var after = before
            change(&after)
            XCTAssertTrue(after.requiresRescan(comparedTo: before), name)
        }
    }

    func testChangesThatOnlyAffectPresentationOrRetentionDoNotRescan() {
        let before = base()
        let changes: [(String, (inout Settings) -> Void)] = [
            ("stale threshold", { $0.staleDays = 90 }),
            ("retention", { $0.trashRetentionDays = 7 }),
            ("unknown key", { $0.unknownKeys["future"] = .bool(true) }),
            ("add a paused folder", { $0.folders.append(FolderSetting(path: URL(fileURLWithPath: "/x"), isEnabled: false)) }),
            ("no change", { _ in }),
        ]
        for (name, change) in changes {
            var after = before
            change(&after)
            XCTAssertFalse(after.requiresRescan(comparedTo: before), name)
        }
    }
}
