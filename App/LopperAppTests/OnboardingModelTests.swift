import XCTest
import Lopper
@testable import LopperApp

@MainActor
final class OnboardingModelTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    private func makeClient() -> FakeEngineClient {
        let client = FakeEngineClient(snapshots: [])
        client.suggestions = [
            FolderSuggestion(path: url("/Users/me/Developer"), repoCount: 12),
            FolderSuggestion(path: url("/Users/me/Code"), repoCount: 0),
        ]
        return client
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testItStartsOnTheWelcomeScreenAndMovesThroughTheSteps() {
        let model = OnboardingModel(client: makeClient(), existingRoots: [])
        XCTAssertEqual(model.step, .welcome)

        model.next()
        XCTAssertEqual(model.step, .choose)

        model.back()
        XCTAssertEqual(model.step, .welcome)
    }

    func testSuggestedFoldersLoadAndOnlyThoseWithReposAreTicked() async {
        let model = OnboardingModel(client: makeClient(), existingRoots: [])

        await model.loadSuggestions()

        XCTAssertTrue(model.suggestionsLoaded)
        XCTAssertEqual(model.candidates.map(\.url.path), ["/Users/me/Developer", "/Users/me/Code"])
        XCTAssertEqual(model.candidates.map(\.isSelected), [true, false])
        XCTAssertEqual(model.selectedURLs.map(\.path), ["/Users/me/Developer"])
        XCTAssertTrue(model.canContinue)
    }

    func testNothingTickedMeansNothingToContinueWith() async {
        let client = makeClient()
        client.suggestions = []
        let model = OnboardingModel(client: client, existingRoots: [])

        await model.loadSuggestions()

        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertFalse(model.canContinue)
    }

    func testFoldersAlreadyBeingScannedAreTickedFromTheStart() async {
        let model = OnboardingModel(client: makeClient(), existingRoots: [url("/Users/me/Work")])

        XCTAssertEqual(model.candidates.map(\.url.path), ["/Users/me/Work"])
        XCTAssertEqual(model.selectedURLs.map(\.path), ["/Users/me/Work"])
    }

    func testTogglingATickedFolderUnticksIt() async {
        let model = OnboardingModel(client: makeClient(), existingRoots: [])
        await model.loadSuggestions()

        model.toggle("/Users/me/Developer")

        XCTAssertFalse(model.canContinue)
        model.toggle("/Users/me/Code")
        XCTAssertEqual(model.selectedURLs.map(\.path), ["/Users/me/Code"])
    }

    func testChosenOrDroppedFoldersAreTickedAndNeverListedTwice() async {
        let model = OnboardingModel(client: makeClient(), existingRoots: [])
        await model.loadSuggestions()
        model.toggle("/Users/me/Developer")

        model.add([url("/Users/me/Developer"), url("/Users/me/Elsewhere")])

        XCTAssertEqual(model.candidates.count, 3)
        XCTAssertEqual(model.selectedURLs.map(\.path).sorted(), ["/Users/me/Developer", "/Users/me/Elsewhere"])
    }

    func testAFolderInsideAnAlreadyListedFolderTicksTheOuterOneInstead() async {
        let model = OnboardingModel(client: makeClient(), existingRoots: [])
        await model.loadSuggestions()
        model.toggle("/Users/me/Developer")

        model.add([url("/Users/me/Developer/api")])

        XCTAssertEqual(model.candidates.count, 2, "the outer folder already covers it")
        XCTAssertEqual(model.selectedURLs.map(\.path), ["/Users/me/Developer"])
    }

    func testTheSystemScanAddsFoldersTicksTheRichOnesAndSkipsThoseAlreadyCovered() async {
        let client = makeClient()
        client.systemScanEvents = [
            .progress(folders: 40, repos: 3),
            .finished([
                DiscoveredFolder(path: url("/Users/me/Developer/clients"), repoCount: 4, sampleNames: ["a"]),
                DiscoveredFolder(path: url("/Users/me/Projects"), repoCount: 9, sampleNames: ["x", "y"]),
                DiscoveredFolder(path: url("/Users/me/loose"), repoCount: 1, sampleNames: ["loose"]),
            ]),
        ]
        let model = OnboardingModel(client: client, existingRoots: [])
        await model.loadSuggestions()

        model.startSystemScan()
        await waitUntil { if case .finished = model.systemScan { true } else { false } }

        XCTAssertEqual(model.systemScan, .finished(found: 2), "clients is already inside Developer")
        let projects = model.candidates.first { $0.url.path == "/Users/me/Projects" }
        XCTAssertEqual(projects?.isSelected, true)
        XCTAssertEqual(projects?.repoCount, 9)
        XCTAssertEqual(model.candidates.first { $0.url.path == "/Users/me/loose" }?.isSelected, false,
                       "a single stray repo is offered, not assumed")
    }

    func testStoppingTheScanKeepsWhatWasFoundSoFar() async {
        let client = makeClient()
        client.systemScanEvents = [.progress(folders: 10, repos: 2)]
        client.systemScanHangs = true
        let model = OnboardingModel(client: client, existingRoots: [])

        model.startSystemScan()
        await waitUntil { if case .running = model.systemScan { true } else { false } }
        model.stopSystemScan()

        XCTAssertEqual(model.systemScan, .stopped(found: 0))
    }

    func testBeginningSavesOnlyTheTickedFoldersAndMovesToTheScanStep() async {
        let client = makeClient()
        let app = AppModel(
            client: client,
            store: SettingsStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("lopper-onb-\(UUID().uuidString).json")),
            settings: Settings(roots: []))
        let model = OnboardingModel(client: client, existingRoots: [])
        await model.loadSuggestions()
        model.next()

        model.begin(app: app)

        XCTAssertEqual(app.settings.roots.map(\.path), ["/Users/me/Developer"])
        XCTAssertEqual(model.step, .scan)
    }

    func testTheAppShowsOnboardingUntilItIsCompletedEvenOnceFoldersAreSaved() {
        let empty = AppModel(
            client: FakeEngineClient(snapshots: []),
            store: SettingsStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("lopper-onb-\(UUID().uuidString).json")),
            settings: Settings(roots: []))
        XCTAssertTrue(empty.isOnboarding)
        empty.setRoots([url("/Users/me/Developer")])
        XCTAssertTrue(empty.isOnboarding, "the payoff screen still has to be seen")

        empty.completeOnboarding()
        XCTAssertFalse(empty.isOnboarding)

        let configured = AppModel(
            client: FakeEngineClient(snapshots: []),
            store: SettingsStore(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("lopper-onb-\(UUID().uuidString).json")),
            settings: Settings(roots: [url("/Users/me/Developer")]))
        XCTAssertFalse(configured.isOnboarding)
        configured.restartOnboarding()
        XCTAssertTrue(configured.isOnboarding)
    }
}
