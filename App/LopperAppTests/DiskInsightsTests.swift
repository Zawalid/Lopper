import XCTest
import Lopper
@testable import LopperApp

final class DiskInsightsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func days(_ n: Int) -> Date { now.addingTimeInterval(-Double(n) * 86_400) }

    private func artifact(
        _ name: String, bytes: Int64, in checkout: String, repo: String = "/code/api",
        location: ArtifactLocation = .mainCheckout, kind: ArtifactKind = .packages,
        removal: ArtifactRemoval = .offered(regenerate: "npm ci")
    ) -> DiskArtifact {
        let root = URL(fileURLWithPath: checkout)
        return DiskArtifact(
            path: root.appendingPathComponent(name), name: name, kind: kind, bytes: bytes, newestModification: nil,
            projectDirectory: root, checkoutRoot: root, repoRoot: URL(fileURLWithPath: repo),
            location: location, removal: removal)
    }

    func testProjectsAreRankedByBuildBytesAndNamedForTheirCheckout() {
        let items = [
            artifact("node_modules", bytes: 400, in: "/code/api"),
            artifact(".next", bytes: 100, in: "/code/api", kind: .frameworkCache),
            artifact("node_modules", bytes: 900, in: "/code/api/.claude/worktrees/fix", location: .worktree(branch: "claude/fix")),
        ]

        let projects = DiskInsights.projects(artifacts: items, sizes: [:])

        XCTAssertEqual(projects.map(\.name), ["api / claude/fix", "api"])
        XCTAssertEqual(projects.map(\.buildBytes), [900, 500])
        XCTAssertEqual(projects[1].artifacts.map(\.name), ["node_modules", ".next"], "biggest folder first")
        XCTAssertTrue(projects[0].isWorktree)
    }

    func testAWorktreeWithoutABranchIsNamedByItsFolder() {
        let item = artifact("dist", bytes: 10, in: "/code/api/.claude/worktrees/try", location: .worktree(branch: nil))
        XCTAssertEqual(DiskInsights.projects(artifacts: [item], sizes: [:]).first?.name, "api / try")
    }

    func testFootprintAndLastEditComeFromTheMeasuredFolder() {
        let item = artifact("node_modules", bytes: 400, in: "/code/api")
        let sizes = ["/code/api": DiskUsage(total: 1_000, disposable: 400, newestModification: days(40))]

        let project = DiskInsights.projects(artifacts: [item], sizes: sizes)[0]

        XCTAssertEqual(project.footprint, 1_000)
        XCTAssertEqual(project.sourceBytes, 600)
        XCTAssertEqual(project.lastEdited, days(40))
        XCTAssertTrue(project.isUntouched(now: now, staleDays: 30))
        XCTAssertFalse(project.isUntouched(now: now, staleDays: 60))
    }

    func testAMeasurementSmallerThanTheGeneratedFoldersIsIgnored() {
        let item = artifact("node_modules", bytes: 400, in: "/code/api")
        let sizes = ["/code/api": DiskUsage(total: 100, disposable: 0, newestModification: days(1))]

        let project = DiskInsights.projects(artifacts: [item], sizes: sizes)[0]

        XCTAssertNil(project.footprint)
        XCTAssertNil(project.sourceBytes)
    }

    func testAnUnmeasuredProjectIsNeverCalledUntouched() {
        let project = DiskInsights.projects(artifacts: [artifact("dist", bytes: 5, in: "/code/api")], sizes: [:])[0]
        XCTAssertNil(project.footprint)
        XCTAssertNil(project.sourceBytes)
        XCTAssertFalse(project.isUntouched(now: now, staleDays: 30))
    }

    func testBlockedFoldersAreCountedButNotClearable() {
        let items = [
            artifact("node_modules", bytes: 300, in: "/code/api"),
            artifact("build", bytes: 200, in: "/code/api", kind: .buildOutput, removal: .blocked(reason: "unknown")),
        ]

        let project = DiskInsights.projects(artifacts: items, sizes: [:])[0]

        XCTAssertEqual(project.buildBytes, 500)
        XCTAssertEqual(project.clearableBytes, 300)
        XCTAssertEqual(project.clearable.map(\.name), ["node_modules"])
        XCTAssertEqual(project.blocked.map(\.name), ["build"])
    }

    func testKindGroupsListWhatBringsEachKindBack() {
        let items = [
            artifact("node_modules", bytes: 300, in: "/code/api"),
            artifact("node_modules", bytes: 200, in: "/code/web", repo: "/code/web", removal: .offered(regenerate: "pnpm install")),
            artifact("node_modules", bytes: 100, in: "/code/old", repo: "/code/old", removal: .offered(regenerate: "npm ci")),
            artifact(".next", bytes: 50, in: "/code/api", kind: .frameworkCache, removal: .offered(regenerate: "your next build or dev run")),
        ]

        let groups = DiskInsights.kinds(artifacts: items)

        XCTAssertEqual(groups.map(\.kind), [.packages, .frameworkCache])
        XCTAssertEqual(groups[0].bytes, 600)
        XCTAssertEqual(groups[0].regenerateHint, "npm ci, pnpm install")
    }

    func testTotalsCountUntouchedProjectsOnlyForWhatCanBeCleared() {
        let items = [
            artifact("node_modules", bytes: 400, in: "/code/api"),
            artifact("node_modules", bytes: 300, in: "/code/old", repo: "/code/old"),
            artifact("build", bytes: 90, in: "/code/old", repo: "/code/old", kind: .buildOutput, removal: .blocked(reason: "x")),
        ]
        let sizes = [
            "/code/api": DiskUsage(total: 1_000, disposable: 0, newestModification: days(2)),
            "/code/old": DiskUsage(total: 800, disposable: 0, newestModification: days(90)),
        ]

        let projects = DiskInsights.projects(artifacts: items, sizes: sizes)
        let totals = DiskInsights.totals(of: projects, now: now, staleDays: 30)

        XCTAssertEqual(totals.projects, 2)
        XCTAssertEqual(totals.folders, 3)
        XCTAssertEqual(totals.footprint, 1_800)
        XCTAssertEqual(totals.buildBytes, 790)
        XCTAssertEqual(totals.clearableBytes, 700)
        XCTAssertEqual(totals.untouchedBytes, 300)
        XCTAssertEqual(totals.untouchedProjects, 1)
    }

    func testFilteringByUntouchedAndByText() {
        let items = [
            artifact("node_modules", bytes: 400, in: "/code/api"),
            artifact("dist", bytes: 300, in: "/code/old", repo: "/code/old"),
        ]
        let sizes = [
            "/code/api": DiskUsage(total: 1, disposable: 0, newestModification: days(2)),
            "/code/old": DiskUsage(total: 1, disposable: 0, newestModification: days(90)),
        ]
        let projects = DiskInsights.projects(artifacts: items, sizes: sizes)

        XCTAssertEqual(
            DiskInsights.filter(projects, untouchedOnly: true, query: "", now: now, staleDays: 30).map(\.name), ["old"])
        XCTAssertEqual(
            DiskInsights.filter(projects, untouchedOnly: false, query: "NODE_", now: now, staleDays: 30).map(\.name),
            ["api"])
        XCTAssertEqual(
            DiskInsights.filter(projects, untouchedOnly: false, query: "  ", now: now, staleDays: 30).count, 2)
    }
}
