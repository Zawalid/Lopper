import XCTest
import Lopper
@testable import LopperApp

/// What the interface reads on every redraw must stay fast with a very large scan: 200 repositories of 40 branches.
/// A redraw that takes longer than this budget is a visible stall.
@MainActor
final class ScaleTests: XCTestCase {
    private func bigModel(repositories: Int = 200, branches: Int = 40) async -> AppModel {
        let snapshots = (0..<repositories).map { index -> RepoSnapshot in
            let root = URL(fileURLWithPath: "/code/group\(index % 10)/repo\(index)")
            let entries = (0..<branches).map { number in
                Fixtures.branch("topic/feature-\(number)", number % 3 == 0 ? .safe : .review, root: root, ageDays: number)
            }
            return Fixtures.snapshot(name: "repo\(index)", root: root, branches: entries)
        }
        let client = FakeEngineClient(snapshots: snapshots)
        let store = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-scale-\(UUID().uuidString).json"))
        let model = AppModel(client: client, store: store, settings: Settings(roots: [URL(fileURLWithPath: "/code")]))
        model.startScan()
        for _ in 0..<2000 {
            if case .ready = model.phase { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return model
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = ContinuousClock.now
        body()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    func testDerivedDataStaysFastWithEightThousandBranches() async {
        let model = await bigModel()
        XCTAssertEqual(model.summaries.count, 200)

        let summaries = milliseconds { _ = model.summaries }
        let totals = milliseconds { _ = model.totals }
        let rows = milliseconds { _ = model.allRows }
        let state = milliseconds { _ = model.overviewState }
        print("SCALE summaries=\(summaries)ms totals=\(totals)ms allRows=\(rows)ms overviewState=\(state)ms")

        XCTAssertLessThan(summaries, 100, "summaries took \(summaries) ms")
        XCTAssertLessThan(totals, 100, "totals took \(totals) ms")
        XCTAssertLessThan(rows, 100, "allRows took \(rows) ms")
        XCTAssertLessThan(state, 100, "overviewState took \(state) ms")
    }
}
