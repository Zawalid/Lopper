import XCTest
import AppKit
import SwiftUI
import Lopper
@testable import LopperApp

final class RepositoryManagerTests: XCTestCase {
    private func repo(_ path: String, hidden: Bool = false, items: Int = 3) -> ManagedRepository {
        let url = URL(fileURLWithPath: path)
        return ManagedRepository(
            name: url.lastPathComponent, root: url, isHidden: hidden, items: items, reclaimableBytes: 0, problem: nil)
    }

    func testRepositoriesGroupByTheirContainingFolderAndSortByName() {
        let groups = RepositoryManagerPresenter.groups(of: [
            repo("/code/startup-saas/web"), repo("/code/agents-lab/docsbot"), repo("/code/startup-saas/api"),
            repo("/code/agents-lab/refactor-lab"),
        ])

        XCTAssertEqual(groups.map(\.name), ["agents-lab", "startup-saas"])
        XCTAssertEqual(groups[0].repositories.map(\.name), ["docsbot", "refactor-lab"])
        XCTAssertEqual(groups[1].repositories.map(\.name), ["api", "web"])
    }

    func testTwoFoldersWithTheSameNameStaySeparate() {
        let groups = RepositoryManagerPresenter.groups(of: [repo("/a/projects/one"), repo("/b/projects/two")])

        XCTAssertEqual(groups.count, 2, "grouping is by full path, not by the folder's name")
    }

    func testSearchMatchesNameAndPathIgnoringCaseAndAccents() {
        let all = [repo("/code/Récup/web"), repo("/code/other/api")]

        func names(_ text: String) -> [String] {
            RepositoryManagerPresenter.groups(of: all, search: text).flatMap(\.repositories).map(\.name)
        }

        XCTAssertEqual(names("recup"), ["web"], "matches the folder in the path")
        XCTAssertEqual(names("API"), ["api"])
        XCTAssertEqual(names("   "), ["api", "web"], "a blank search shows everything")
        XCTAssertTrue(names("nothing like it").isEmpty)
    }

    func testTheMostSpecificEnabledFolderOwnsARepository() {
        let outer = FolderSetting(path: URL(fileURLWithPath: "/code"))
        let inner = FolderSetting(path: URL(fileURLWithPath: "/code/demo"))
        let paused = FolderSetting(path: URL(fileURLWithPath: "/code/demo/deep"), isEnabled: false)

        let owner = RepositoryManagerPresenter.owningFolder(
            of: URL(fileURLWithPath: "/code/demo/deep/app"), in: [outer, inner, paused])

        XCTAssertEqual(owner?.path.path, "/code/demo", "a paused folder does not own anything")
        XCTAssertNil(RepositoryManagerPresenter.owningFolder(of: URL(fileURLWithPath: "/elsewhere/app"), in: [outer]))
        XCTAssertNil(
            RepositoryManagerPresenter.owningFolder(of: URL(fileURLWithPath: "/codex/app"), in: [outer]),
            "/code must not own /codex")
    }

    func testOnlyPlainFolderNamesCanBeSkipped() {
        XCTAssertTrue(RepositoryManagerPresenter.canSkip(folderNamed: "LopperDemo"))
        XCTAssertFalse(RepositoryManagerPresenter.canSkip(folderNamed: "legacy-*"))
        XCTAssertFalse(RepositoryManagerPresenter.canSkip(folderNamed: ""))
    }

    @MainActor
    private func makeModel(roots: [URL]) -> AppModel {
        let store = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-manager-\(UUID().uuidString).json"))
        return AppModel(client: FakeEngineClient(snapshots: []), store: store, settings: Settings(roots: roots))
    }

    @MainActor
    func testHidingSeveralRepositoriesIsOneChangeAndShowingThemBringsThemBack() {
        let model = makeModel(roots: [URL(fileURLWithPath: "/code")])
        let a = URL(fileURLWithPath: "/code/demo/a")
        let b = URL(fileURLWithPath: "/code/demo/b")

        model.hideRepositories([a, b])

        XCTAssertTrue(model.settings.isIgnored(a))
        XCTAssertTrue(model.settings.isIgnored(b))
        XCTAssertEqual(model.hiddenRepositories.map(\.name), ["a", "b"])

        model.showRepositories([a])

        XCTAssertFalse(model.settings.isIgnored(a))
        XCTAssertNil(model.settings.repos[a.path], "an empty override is not kept")
        XCTAssertEqual(model.hiddenRepositories.map(\.name), ["b"])
    }

    @MainActor
    func testShowingARepositoryKeepsItsOtherSettings() {
        let model = makeModel(roots: [URL(fileURLWithPath: "/code")])
        let repository = URL(fileURLWithPath: "/code/app")
        model.updateSettings { $0.repos[repository.path] = RepoOverrides(defaultBranch: "develop", isIgnored: true) }

        model.showRepositories([repository])

        XCTAssertFalse(model.settings.isIgnored(repository))
        XCTAssertEqual(model.settings.defaultBranchOverride(for: repository), "develop")
    }

    @MainActor
    func testSkippingAFolderNameAddsItToTheFolderThatHoldsItAndCanBeUndone() {
        let root = URL(fileURLWithPath: "/code")
        let model = makeModel(roots: [root])
        let inside = URL(fileURLWithPath: "/code/LopperDemo/web")

        XCTAssertTrue(model.skipFolderNamed("LopperDemo", containing: inside))
        XCTAssertTrue(model.skipFolderNamed("LopperDemo", containing: inside), "asking twice adds it once")
        XCTAssertEqual(model.settings.folders.first?.excludePatterns, ["LopperDemo"])

        model.stopSkippingFolderNamed("LopperDemo")

        XCTAssertEqual(model.settings.folders.first?.excludePatterns, [])
    }

    @MainActor
    func testSkippingRefusesWhenNoFolderOwnsTheRepositoryOrTheNameIsAGlob() {
        let model = makeModel(roots: [URL(fileURLWithPath: "/code")])

        XCTAssertFalse(model.skipFolderNamed("x", containing: URL(fileURLWithPath: "/elsewhere/x/app")))
        XCTAssertFalse(model.skipFolderNamed("legacy-*", containing: URL(fileURLWithPath: "/code/legacy-1/app")))
        XCTAssertEqual(model.settings.folders.first?.excludePatterns, [])
    }

    @MainActor
    func testSheetRendersWithGroupsHiddenRepositoriesAndFolders() async throws {
        func snapshot(_ name: String, in folder: String, safe: Int, review: Int) -> RepoSnapshot {
            let root = URL(fileURLWithPath: "/Users/walid/Personal/Projects/\(folder)/\(name)")
            let branches = (0..<safe).map { Fixtures.branch("done-\($0)", .safe, root: root) }
                + (0..<review).map { Fixtures.branch("wip-\($0)", .review, root: root) }
                + [Fixtures.branch("main", .protected, root: root)]
            return Fixtures.snapshot(name: name, root: root, branches: branches)
        }
        let demo = ["docsbot", "agent-playground", "refactor-lab", "tinyhash"].map { snapshot($0, in: "LopperDemo/agents-lab", safe: 2, review: 1) }
            + ["web", "api", "docs"].map { snapshot($0, in: "LopperDemo/startup-saas", safe: 3, review: 2) }
        let real = ["Lopper", "Formatex"].map { snapshot($0, in: ".", safe: 1, review: 1) }
        let model = await RenderSupport.makeModel(
            snapshots: demo + real, roots: [URL(fileURLWithPath: "/Users/walid/Personal/Projects")])
        model.hideRepositories([URL(fileURLWithPath: "/Users/walid/Personal/Projects/LopperDemo/client-work/bluebird-studio")])

        XCTAssertEqual(model.listedRepositories.count, 9)
        let groups = RepositoryManagerPresenter.groups(of: model.listedRepositories)
        try RenderSupport.render(
            "manage-repositories", size: CGSize(width: 720, height: 640),
            ManageGroupsList(
                groups: groups, listing: .listed, selection: .constant(["/Users/walid/Personal/Projects/LopperDemo/agents-lab/docsbot"]),
                onHide: { _, _ in }, onShow: { _ in }, onSkip: { _ in })
            .environment(model).padding(24))
    }

    /// A snapshot of the real sheet in a real window, so the checkboxes, pickers and menus are drawn. Only runs when
    /// `LOPPER_SNAPSHOT_DIR` is set (pass it as `TEST_RUNNER_LOPPER_SNAPSHOT_DIR`).
    @MainActor
    func testWriteSnapshotsOfTheSheetInARealWindow() throws {
        guard let directory = ProcessInfo.processInfo.environment["LOPPER_SNAPSHOT_DIR"] else {
            throw XCTSkip("set LOPPER_SNAPSHOT_DIR to write snapshots")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        func snapshot(_ name: String, in folder: String) -> RepoSnapshot {
            let root = URL(fileURLWithPath: "/Users/walid/Personal/Projects/\(folder)/\(name)")
            return Fixtures.snapshot(name: name, root: root, branches: [
                Fixtures.branch("done", .safe, root: root), Fixtures.branch("wip", .review, root: root),
                Fixtures.branch("main", .protected, root: root),
            ])
        }
        let model = AppModel.preview(
            snapshots: ["docsbot", "agent-playground", "refactor-lab"].map { snapshot($0, in: "LopperDemo/agents-lab") }
                + ["web", "api"].map { snapshot($0, in: "LopperDemo/startup-saas") }
                + [snapshot("Lopper", in: "Work")],
            history: [], route: .overview, clock: { Fixtures.now })
        model.hideRepositories([URL(fileURLWithPath: "/Users/walid/Personal/Projects/LopperDemo/client-work/bluebird")])

        let controller = NSHostingController(rootView: ManageRepositoriesSheet().environment(model))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 760, height: 680))
        window.makeKeyAndOrderFront(nil)
        for appearance in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            window.appearance = NSAppearance(named: appearance.1)
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: "\(directory)/manage-sheet-\(appearance.0).png"))
            }
        }
        window.close()
    }
}
