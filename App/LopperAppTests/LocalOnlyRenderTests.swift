import XCTest
import SwiftUI
import Lopper
@testable import LopperApp

@MainActor
final class LocalOnlyRenderTests: XCTestCase {
    func testPageRendersWithEveryKind() async throws {
        let root = URL(fileURLWithPath: "/code")
        let other = URL(fileURLWithPath: "/code/apps")
        func item(_ kind: LocalOnlyItem.Kind, _ title: String, _ detail: String, root: URL, push: String? = nil) -> LocalOnlyItem {
            LocalOnlyItem(
                id: "\(kind.rawValue)-\(title)", kind: kind, repoRoot: root, repoName: root.lastPathComponent, title: title,
                detail: detail, count: 1, lastTouched: Date().addingTimeInterval(-86_400 * 12), branch: title, pushCommand: push)
        }
        let client = FakeEngineClient(snapshots: [Fixtures.sample])
        client.localOnly = [
            item(.unpushedCommits, "feature/onboarding", "3 commits not on any remote", root: root, push: "git push"),
            item(.uncommittedChanges, "fix/crash", "Uncommitted changes and 2 untracked files", root: root),
            item(.stash, "stash@{0}", "Stashed on main: half done idea", root: other),
            item(.detachedCommits, "experiment", "1 commit that no branch, tag or remote has", root: other),
            item(.operationInProgress, "release", "A rebase, merge or similar operation is half done here", root: other),
        ]
        let store = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-localonly-\(UUID().uuidString).json"))
        let model = AppModel(client: client, store: store, settings: Settings(roots: [root]))
        model.startScan()
        for _ in 0..<300 where !model.localOnlyLoaded { try? await Task.sleep(for: .milliseconds(10)) }

        XCTAssertEqual(model.localOnlyPageState, .ready)
        XCTAssertEqual(model.localOnlyGroups.count, 2)
        try RenderSupport.render("only-here", size: CGSize(width: 900, height: 640), LocalOnlyList().environment(model))
    }

    func testBusyPageRendersWithOpenRowsAndDetail() async throws {
        let api = URL(fileURLWithPath: "/code/api")
        let apps = URL(fileURLWithPath: "/code/apps")
        func make(_ kind: LocalOnlyItem.Kind, _ title: String, _ detail: String, repo: URL, count: Int = 0, age: Int,
                  tracked: Bool = false, push: Bool = false) -> LocalOnlyItem {
            LocalOnlyItem(
                id: "\(kind.rawValue)-\(repo.lastPathComponent)-\(title)", kind: kind, repoRoot: repo,
                repoName: repo.lastPathComponent, title: title, detail: detail, count: count,
                lastTouched: Date().addingTimeInterval(-86_400 * Double(age)), branch: title,
                pushCommand: push ? "git -C /code/api push -u origin \(title)" : nil, hasTrackedChanges: tracked)
        }
        var items = [
            make(.unpushedCommits, "verif/final-api-2", "14 commits not on any remote", repo: api, count: 14, age: 11, push: true),
            make(.unpushedCommits, "verif/fusion-lot2", "11 commits not on any remote", repo: api, count: 11, age: 15, push: true),
            make(.unpushedCommits, "recuperation/erp-essai", "13 commits not on any remote", repo: api, count: 13, age: 16, push: true),
            make(.detachedCommits, "api-scope", "2 commits that no branch, tag or remote has", repo: api, count: 2, age: 23),
            make(.uncommittedChanges, "fix/crash", "Uncommitted changes and 2 untracked files", repo: api, count: 2, age: 0, tracked: true),
            make(.stash, "stash@{0}", "Stashed on main: half done idea", repo: apps, age: 4),
        ]
        for number in 1...9 {
            items.append(make(.unpushedCommits, "feature/part-\(number)", "\(number) commits not on any remote", repo: api,
                              count: number, age: 20 + number, push: true))
        }
        for name in ["api-k485", "api-k495base", "fix/la-notification"] {
            items.append(make(.uncommittedChanges, name, "2 untracked files", repo: api, count: 2, age: 0))
        }
        let client = FakeEngineClient(snapshots: [Fixtures.sample])
        client.localOnly = items
        client.localOnlyDetails[items[0].id] = LocalOnlyDetail(
            lines: ["a1b2c3d  fix the cycle report totals", "9f8e7d6  add the surveillance endpoint", "4c5d6e7  wip fusion"],
            hiddenCount: 11)
        client.localOnlyDetails[items[4].id] = LocalOnlyDetail(lines: [" M src/report.ts", "?? notes.md", "?? scratch/"])
        let store = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-localonly-\(UUID().uuidString).json"))
        let model = AppModel(client: client, store: store, settings: Settings(roots: [api]))
        model.startScan()
        for _ in 0..<300 where !model.localOnlyLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        await model.loadLocalOnlyDetail(items[0])
        await model.loadLocalOnlyDetail(items[4])

        try RenderSupport.render(
            "only-here-busy", size: CGSize(width: 900, height: 1500),
            LocalOnlyList(initiallyOpen: [items[0].id, items[4].id]).environment(model))
    }

    func testEmptyPageRenders() async throws {
        let model = await RenderSupport.makeModel(snapshots: [Fixtures.sample])
        for _ in 0..<300 where !model.localOnlyLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.localOnlyPageState, .allBackedUp(repositories: 1))
        try RenderSupport.render("only-here-empty", size: CGSize(width: 820, height: 420), LocalOnlyContent().environment(model))
    }
}
