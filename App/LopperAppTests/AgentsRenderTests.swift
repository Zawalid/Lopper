import XCTest
import SwiftUI
import Lopper
@testable import LopperApp

@MainActor
final class AgentsRenderTests: XCTestCase {
    private func ready() -> AppModel {
        let m = Fixtures.agentMeasurements
        return AppModel.preview(
            snapshots: [Fixtures.agentSample], sizes: m.sizes, activity: m.activity,
            route: .agents, clock: { Fixtures.now })
    }

    func testPageRendersInEveryState() throws {
        let size = CGSize(width: 820, height: 560)
        let states: [(String, AppModel)] = [
            ("agents-ready", ready()),
            ("agents-none", AppModel.preview(snapshots: [Fixtures.sample], route: .agents)),
            ("agents-folders", AppModel.preview(snapshots: [], roots: [], route: .agents)),
            ("agents-scanning", AppModel.preview(
                snapshots: [], route: .agents, phase: .scanning(done: 1, total: 4))),
        ]
        for (name, model) in states {
            try RenderSupport.render(name, size: size, AgentsContent().environment(model))
        }
    }

    func testStateLabelsAreThePromisedWords() {
        XCTAssertEqual(AgentState.unmerged.label, "Not merged")
        XCTAssertEqual(AgentState.finished.label, "Finished")
        XCTAssertEqual(AgentState.abandoned.label, "Abandoned")
        XCTAssertEqual(AgentState.active.label, "Active")
    }

    func testRoutePersistsAsAgents() {
        XCTAssertEqual(PreferencesRoute.encode(.agents), "agents")
        XCTAssertEqual(PreferencesRoute.decode("agents"), .agents)
    }
}
