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

    func testEmptyPageRenders() async throws {
        let model = await RenderSupport.makeModel(snapshots: [Fixtures.sample])
        for _ in 0..<300 where !model.localOnlyLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.localOnlyPageState, .allBackedUp(repositories: 1))
        try RenderSupport.render("only-here-empty", size: CGSize(width: 820, height: 420), LocalOnlyContent().environment(model))
    }
}
