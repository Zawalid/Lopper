import XCTest
import SwiftUI
import Lopper
@testable import LopperApp

@MainActor
final class SetupIssueRenderTests: XCTestCase {
    private func model(tools: ToolStatus? = nil, access: [String: FolderAccess] = [:]) async -> AppModel {
        let client = FakeEngineClient(snapshots: [])
        if let tools { client.tools = tools }
        client.folderAccessOverrides = access
        let store = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-setup-\(UUID().uuidString).json"))
        let model = AppModel(client: client, store: store, settings: Settings(roots: [URL(fileURLWithPath: "/code")]))
        await model.refreshToolStatus()
        await model.refreshFolderAccess()
        return model
    }

    func testGitMissingScreenRenders() async throws {
        let model = await model(tools: ToolStatus(gitVersion: nil, gitHubCLI: .notInstalled))
        XCTAssertEqual(model.setupIssue, .gitMissing)
        try RenderSupport.render("setup-git", size: CGSize(width: 720, height: 460),
                                 SetupIssueView(issue: .gitMissing).environment(model))
    }

    func testDeniedFoldersScreenRenders() async throws {
        let model = await model(access: [URL(fileURLWithPath: "/code").canonicalized.path: .denied])
        XCTAssertEqual(model.setupIssue, .foldersUnreadable)
        try RenderSupport.render("setup-access", size: CGSize(width: 720, height: 520),
                                 SetupIssueView(issue: .foldersUnreadable).environment(model))
    }

    func testMissingFoldersScreenRenders() async throws {
        let model = await model(access: [URL(fileURLWithPath: "/code").canonicalized.path: .missing])
        try RenderSupport.render("setup-missing", size: CGSize(width: 720, height: 520),
                                 SetupIssueView(issue: .foldersUnreadable).environment(model))
    }
}
