import XCTest
import SwiftUI
import Lopper
@testable import LopperApp

/// When GitHub cannot be reached the app says so plainly, keeps working from what git can prove, and checks again by
/// itself once the connection is back.
@MainActor
final class OfflineModelTests: XCTestCase {
    private func snapshot(remote: String?, available: Bool = false, offline: Bool) -> RepoSnapshot {
        RepoSnapshot(
            repo: Repo(root: URL(fileURLWithPath: "/code/r"), name: "r", defaultBranch: "main", remoteURL: remote),
            branches: [], worktrees: [], prDetectionAvailable: available, prOffline: offline, scannedAt: Date())
    }

    private func makeModel(_ snapshots: [RepoSnapshot]) async -> (AppModel, FakeEngineClient) {
        let client = FakeEngineClient(snapshots: snapshots)
        let store = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-test-settings-\(UUID().uuidString).json"))
        let model = AppModel(client: client, store: store, settings: Settings(roots: [URL(fileURLWithPath: "/code")]))
        model.startScan()
        await settle(model)
        return (model, client)
    }

    private func settle(_ model: AppModel) async {
        for _ in 0..<300 {
            if case .ready = model.phase { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Saying so

    func testTheAppIsOfflineOnlyForRepositoriesThatLiveOnGitHub() async {
        let online = await makeModel([snapshot(remote: "git@github.com:acme/r.git", available: true, offline: false)]).0
        XCTAssertFalse(online.isOffline)

        let offline = await makeModel([snapshot(remote: "git@github.com:acme/r.git", offline: true)]).0
        XCTAssertTrue(offline.isOffline)
        XCTAssertEqual(offline.offlineRepositoryCount, 1)

        let noRemote = await makeModel([snapshot(remote: nil, offline: true)]).0
        XCTAssertFalse(noRemote.isOffline, "a repository with no GitHub remote has nothing to be offline about")
    }

    func testOfflineHasItsOwnNoteAndTheMissingCliNoteStaysForTheMissingCli() async {
        let offline = await makeModel([snapshot(remote: "git@github.com:acme/r.git", offline: true)]).0
        XCTAssertFalse(offline.prDetectionNote, "do not ask someone who is offline to connect a tool")

        let missing = await makeModel([snapshot(remote: "git@github.com:acme/r.git", offline: false)]).0
        XCTAssertTrue(missing.prDetectionNote)
        XCTAssertFalse(missing.isOffline)
    }

    func testTheOfflineMessageNamesTheConsequenceAndTheWayOut() async {
        let (model, _) = await makeModel([snapshot(remote: "git@github.com:acme/r.git", offline: true)])

        let message = model.offlineMessage

        XCTAssertTrue(message.contains("offline") || message.contains("reach GitHub"))
        XCTAssertTrue(message.contains("Review"), "it says what changes for the person's branches")
    }

    func testTheInspectorSaysGitHubCouldNotBeReachedInsteadOfAskingForAnInstall() {
        let facts = RowFacts(evidence: .none, defaultBranch: "main", prDetectionAvailable: false, prOffline: true)
        let row = CleanupRow(
            id: "x", kind: .branch, repoRoot: URL(fileURLWithPath: "/code/r"), repoName: "r", title: "feature",
            location: "Local branch", path: nil, verdict: .review, reasons: [], evidence: "", prNumber: nil, prURL: nil,
            lastCommit: nil, size: nil, agentHint: nil, extraFiles: [], bundledBranch: nil, facts: facts)

        let check = InspectorInsights.checklist(for: row).first { $0.id == "pr" }

        XCTAssertEqual(check?.title, "Pull requests were not checked")
        XCTAssertTrue(check?.detail?.contains("GitHub could not be reached") ?? false)
        XCTAssertFalse(check?.detail?.contains("Install") ?? true)
    }

    // MARK: Coming back

    func testComingBackOnlineRescansWhenPullRequestsWereSkipped() async {
        let (model, client) = await makeModel([snapshot(remote: "git@github.com:acme/r.git", offline: true)])
        let before = client.scanRequests

        model.networkBecameReachable()
        await settle(model)

        XCTAssertEqual(client.scanRequests, before + 1)
    }

    func testComingBackOnlineDoesNothingWhenNothingWasSkipped() async {
        let (model, client) = await makeModel([snapshot(remote: "git@github.com:acme/r.git", available: true, offline: false)])
        let before = client.scanRequests

        model.networkBecameReachable()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(client.scanRequests, before)
    }

    func testAPullRequestLookupThatFailedOfflineIsAskedAgainAfterTheNextScan() async {
        let (model, client) = await makeModel([Fixtures.sample])
        let row = model.allRows[0]
        await model.loadDetails(for: row)
        XCTAssertNil(model.pullRequest(for: row))
        client.pullRequests[row.title] = PullRequestStatus(
            number: 3, title: "t", state: .open, isDraft: false, review: .none, checks: .none, url: nil)

        model.startScan()
        await settle(model)
        await model.loadDetails(for: model.allRows[0])

        XCTAssertEqual(model.pullRequest(for: model.allRows[0])?.number, 3)
    }

    func testTheOfflineBannerRenders() async throws {
        let (model, _) = await makeModel([snapshot(remote: "git@github.com:acme/r.git", offline: true)])
        XCTAssertTrue(model.isOffline)

        try RenderSupport.render(
            "offline-banner", size: CGSize(width: 720, height: 110),
            OfflineBanner().padding(16).environment(model))
    }
}
