import XCTest
@testable import LopperApp

final class LopperSceneTests: XCTestCase {
    func testTheGraphIsTheSameEveryTimeSoTheLoopNeverJumps() {
        let first = SceneGraph.make()
        let second = SceneGraph.make()

        XCTAssertEqual(first.branches.count, second.branches.count)
        XCTAssertEqual(first.branches.map(\.attach), second.branches.map(\.attach))
        XCTAssertEqual(first.branches.map(\.kind), second.branches.map(\.kind))
    }

    func testThereAreMoreBranchesToKeepThanToCutAndEveryCutBranchIsAtTheTrunkOrAChild() {
        let graph = SceneGraph.make()
        let stale = graph.branches.filter { $0.kind == .stale }
        let kept = graph.branches.filter { $0.kind != .stale }

        XCTAssertEqual(stale.count, SceneTimeline.cutCount)
        XCTAssertGreaterThan(kept.count, stale.count)
        for branch in graph.branches where branch.parent != nil {
            XCTAssertLessThan(branch.parent!, graph.branches.count)
        }
    }

    func testCutsHappenOneAfterAnotherInsideTheLoopWithTimeToSeeTheResult() {
        let times = SceneTimeline.cutTimes
        XCTAssertEqual(times.count, SceneTimeline.cutCount)
        XCTAssertEqual(times, times.sorted())
        XCTAssertGreaterThan(times.first!, SceneTimeline.firstScissorsArrival)
        XCTAssertLessThan(times.last! + 2, SceneTimeline.period, "the result is on screen before it loops")
    }

    func testTheCounterOnlyGoesUpAndEndsAtTheTotal() {
        var previous = -1.0
        for step in stride(from: 0.0, through: SceneTimeline.period, by: 0.1) {
            let value = SceneTimeline.freedGB(at: step)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
        XCTAssertEqual(SceneTimeline.freedGB(at: 0), 0)
        XCTAssertEqual(SceneTimeline.freedGB(at: SceneTimeline.period - 0.5), SceneTimeline.totalGB, accuracy: 0.001)
    }

    func testTheStillFrameForReducedMotionShowsTheFinishedPicture() {
        XCTAssertGreaterThan(SceneTimeline.stillFrame, SceneTimeline.cutTimes.last!)
        XCTAssertEqual(SceneTimeline.freedGB(at: SceneTimeline.stillFrame), SceneTimeline.totalGB, accuracy: 0.001)
    }

    func testTheRandomNumbersAreStableAcrossRuns() {
        var first = SplitMix(seed: 7)
        var second = SplitMix(seed: 7)
        XCTAssertEqual((0..<5).map { _ in first.next() }, (0..<5).map { _ in second.next() })
        var generator = SplitMix(seed: 1)
        for _ in 0..<100 {
            let value = generator.unit()
            XCTAssertTrue(value >= 0 && value < 1)
        }
    }
}
