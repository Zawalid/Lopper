import XCTest
import Lopper
@testable import LopperApp

@MainActor
final class DiskModelTests: XCTestCase {
    private let mainPath = "/code/api"
    private let worktreePath = "/code/wt/feat/in-worktree"

    private func artifact(
        _ name: String, bytes: Int64, in checkout: String, location: ArtifactLocation = .mainCheckout,
        kind: ArtifactKind = .packages, removal: ArtifactRemoval = .offered(regenerate: "npm ci")
    ) -> DiskArtifact {
        let root = URL(fileURLWithPath: checkout)
        return DiskArtifact(
            path: root.appendingPathComponent(name), name: name, kind: kind, bytes: bytes, newestModification: nil,
            projectDirectory: root, checkoutRoot: root, repoRoot: Fixtures.root, location: location, removal: removal)
    }

    private func makeModel(
        snapshots: [RepoSnapshot] = [Fixtures.sample], artifacts: [String: [DiskArtifact]]? = nil
    ) -> (AppModel, FakeEngineClient) {
        let client = FakeEngineClient(snapshots: snapshots)
        client.artifactsByRoot = artifacts ?? [
            mainPath: [
                artifact("node_modules", bytes: 900, in: mainPath),
                artifact("build", bytes: 100, in: mainPath, kind: .buildOutput, removal: .blocked(reason: "unknown")),
            ],
            worktreePath: [
                artifact("node_modules", bytes: 500, in: worktreePath, location: .worktree(branch: "feat/in-worktree")),
            ],
        ]
        let store = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-test-settings-\(UUID().uuidString).json"))
        let model = AppModel(client: client, store: store, settings: Settings(roots: [URL(fileURLWithPath: "/code")]))
        return (model, client)
    }

    private func settle(_ model: AppModel) async {
        for _ in 0..<300 {
            if case .ready = model.phase, case .ready = model.artifactPhase { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testAScanLooksInTheMainFolderAndEveryWorktree() async {
        let (model, client) = makeModel()
        model.startScan()
        await settle(model)

        XCTAssertTrue(client.artifactScans.contains(mainPath))
        XCTAssertTrue(client.artifactScans.contains(worktreePath))
        XCTAssertEqual(model.artifacts.count, 3)
        XCTAssertEqual(model.diskTotals.buildBytes, 1_500)
        XCTAssertEqual(model.diskTotals.clearableBytes, 1_400)
        XCTAssertEqual(model.diskPageState, .ready)
    }

    func testMainFoldersAreMeasuredWithoutTheWorktreesNestedInsideThem() async {
        let nested = WorktreeEntry(
            repoRoot: Fixtures.root, path: URL(fileURLWithPath: "/code/api/.claude/worktrees/x"), head: "abc",
            branch: "claude/x", isMain: false, isLocked: false, isPrunable: false,
            status: WorktreeStatus(isDirty: false, extraFiles: [], disposablePaths: []),
            operationInProgress: false, evidence: .ancestorOfDefault,
            verdict: Fixtures.verdict(.safe), agentHint: nil)
        let snapshot = Fixtures.snapshot(
            branches: [Fixtures.branch("feat/a", .safe)],
            worktrees: [Fixtures.worktree("feat/in-worktree", .safe), nested])
        let (model, client) = makeModel(snapshots: [snapshot], artifacts: [:])
        model.startScan()
        await settle(model)

        let main = client.measurements.first { $0.path == mainPath }
        XCTAssertEqual(main?.excluding, ["/code/api/.claude/worktrees/x"])
        let other = client.measurements.first { $0.path == worktreePath }
        XCTAssertEqual(other?.excluding, [])
    }

    func testNothingFoundIsSaidPlainly() async {
        let (model, _) = makeModel(artifacts: [:])
        model.startScan()
        await settle(model)

        XCTAssertEqual(model.diskPageState, .nothingFound(projects: 1))
    }

    func testClearingAProjectOffersOnlyWhatCanBeBroughtBack() async {
        let (model, _) = makeModel()
        model.startScan()
        await settle(model)

        model.beginClear(project: mainPath)

        XCTAssertEqual(model.diskClear?.artifacts.map(\.name), ["node_modules"])
        XCTAssertEqual(model.diskClear?.includedBytes, 900)
    }

    func testClearingSendsOnlyTheIncludedFoldersAndOffersUndo() async {
        let (model, client) = makeModel()
        model.startScan()
        await settle(model)
        model.beginClearAllClearable()
        let skipped = model.diskClear?.artifacts.first { $0.checkoutRoot.path == worktreePath }
        model.setDiskExcluded(skipped?.id ?? "", true)

        model.runDiskClear()
        await waitUntil { model.diskClear?.phase == .finished }

        XCTAssertEqual(client.clearedArtifacts.map(\.path.path), ["/code/api/node_modules"])
        XCTAssertEqual(model.diskClear?.removed, 1)
        XCTAssertEqual(model.diskClear?.reclaimedBytes, 900)
        XCTAssertEqual(model.toast?.removed, 1)
        XCTAssertEqual(model.toast?.reclaimed, 900)
        XCTAssertEqual(model.toast?.folders, true)
    }

    func testAFolderTheEngineRefusedIsReportedAndGivesNoToast() async {
        let (model, client) = makeModel()
        client.clearArtifactOutcome = { _ in .skipped(reason: "This folder is no longer ignored by git") }
        model.startScan()
        await settle(model)
        model.beginClear(project: mainPath)

        model.runDiskClear()
        await waitUntil { model.diskClear?.phase == .finished }

        XCTAssertEqual(model.diskClear?.removed, 0)
        XCTAssertEqual(model.diskClear?.problemCount, 1)
        XCTAssertNil(model.toast)
    }

    func testTheSheetDoesNotOpenOverTheCleanupSheet() async {
        let (model, _) = makeModel()
        model.startScan()
        await settle(model)
        model.beginCleanAllSafe()
        XCTAssertNotNil(model.clean)

        model.beginClear(project: mainPath)

        XCTAssertNil(model.diskClear)
    }

    func testTheAgentsActionClearsOnlyThatWorktreesFolders() async {
        let (model, _) = makeModel()
        model.startScan()
        await settle(model)

        model.beginClearBuildFolders(inWorktree: worktreePath, named: "feat/in-worktree")

        XCTAssertEqual(model.diskClear?.artifacts.map(\.checkoutRoot.path), [worktreePath])
        XCTAssertEqual(model.diskClear?.title, "Clear build folders in feat/in-worktree")
    }

    func testUntouchedProjectsAreTheOnesNobodyEditedForTheStaleWindow() async {
        let (model, client) = makeModel()
        client.sizeByPath = [mainPath: 5_000, worktreePath: 2_000]
        client.activityByPath = [
            mainPath: Date().addingTimeInterval(-3 * 86_400),
            worktreePath: Date().addingTimeInterval(-90 * 86_400),
        ]
        model.startScan()
        await settle(model)
        await waitUntil { model.sizes.count >= 2 }

        XCTAssertEqual(model.diskTotals.untouchedBytes, 500)
        model.diskUntouchedOnly = true
        XCTAssertEqual(model.visibleDiskProjects.map(\.id), [worktreePath])
    }

    func testClearedFoldersStillInTheTrashAreCountedAndCanBeDeletedForGood() async {
        let (model, client) = makeModel()
        let record = UndoRecord(
            timestamp: Date(), repoPath: "/code/api", action: .trashFolder, branch: nil, tip: "", upstream: nil,
            worktreePath: "/code/api/node_modules", trashRef: "", status: .completed, bytes: 900,
            trashedPath: "/Users/me/.Trash/node_modules")
        client.trashed = [record]
        model.startScan()
        await settle(model)
        XCTAssertEqual(model.trashedTotals.folders, 1)
        XCTAssertEqual(model.trashedTotals.bytes, 900)

        model.deleteTrashedForGood()
        await waitUntil { model.trashedTotals.folders == 0 }

        XCTAssertEqual(client.deletedForGood.map(\.id), [record.id])
        XCTAssertEqual(model.trashedTotals.bytes, 0)
    }

    func testDeveloperCachesAndFreeSpaceAreLoadedWithTheScan() async {
        let (model, client) = makeModel()
        client.caches = [Fixtures.developerCaches[0]]
        client.volume = VolumeSpace(total: 1_000, available: 400)
        model.startScan()
        await settle(model)

        XCTAssertEqual(model.developerCaches.map(\.name), ["Xcode build data"])
        XCTAssertEqual(model.volumeSpace?.used, 600)
    }

    func testClearingDeveloperCachesUsesTheSameReviewSheet() async {
        let (model, client) = makeModel()
        client.caches = Fixtures.developerCaches
        model.startScan()
        await settle(model)

        model.beginClearDeveloperCaches()

        XCTAssertEqual(model.diskClear?.artifacts.count, 2)
        XCTAssertEqual(model.diskClear?.title, "Clear developer caches")
    }
}
