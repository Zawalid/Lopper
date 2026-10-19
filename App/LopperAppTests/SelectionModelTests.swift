import XCTest
import AppKit
import SwiftUI
import Lopper
@testable import LopperApp

/// What happens to the selection when a person clicks, shift-clicks, uses the header checkbox or a menu.
@MainActor
final class SelectionModelTests: XCTestCase {
    private func makeModel() -> (AppModel, [CleanupRow]) {
        let model = AppModel.preview(snapshots: [Fixtures.sample], route: .repo(Fixtures.root.path), clock: { Fixtures.now })
        let rows = model.visibleRows(forRepo: Fixtures.root.path)
        return (model, rows)
    }

    private func titles(_ model: AppModel) -> Set<String> {
        Set(model.allRows.filter { model.checked.contains($0.id) }.map(\.title))
    }

    func testChoosingARowFromAnywhereSelectsIt() {
        let (model, rows) = makeModel()

        model.focusedRowID = rows[1].id

        XCTAssertEqual(model.checked, [rows[1].id], "the inspector's row is always a selected row")
    }

    func testAPlainClickReplacesTheSelectionAndAnExtendedClickAddsToIt() {
        let (model, rows) = makeModel()
        model.updateSelection(fromTable: [rows[0].id])

        model.updateSelection(fromTable: [rows[1].id])
        XCTAssertEqual(model.checked, [rows[1].id])

        model.updateSelection(fromTable: [rows[1].id, rows[2].id])
        XCTAssertEqual(model.checked, [rows[1].id, rows[2].id])
        XCTAssertEqual(model.focusedRowID, rows[2].id, "the row just added is the one the inspector shows")
    }

    func testChoosingASectionHeaderChoosesItsRowsAndNeverTheHeader() {
        let (model, rows) = makeModel()
        let section = "group:verdict:Safe"
        let safe = rows.filter { $0.verdict == .safe }
        let locked = rows.first { $0.verdict == .protected }!

        model.updateSelection(fromTable: [section], sections: [section: safe + [locked]])

        XCTAssertEqual(model.checked, Set(safe.map(\.id)), "protected rows are not picked through a header")
        XCTAssertFalse(model.checked.contains(section))
    }

    func testShiftClickingACheckboxPicksTheRangeFromTheLastRowClicked() {
        let (model, rows) = makeModel()
        let selectable = rows.filter(\.isSelectable)
        model.toggleChecked(selectable[0], extendingRange: false, order: rows)

        model.toggleChecked(selectable[3], extendingRange: true, order: rows)

        let expected = Set(RowSelection.range(from: selectable[0].id, to: selectable[3].id, in: rows.map(\.id))
            .filter { id in selectable.contains { $0.id == id } })
        XCTAssertEqual(model.checked, expected)
        XCTAssertGreaterThan(model.checked.count, 2)
    }

    func testShiftClickingTurnsTheWholeRangeOffWhenTheClickedRowWasOn() {
        let (model, rows) = makeModel()
        model.applyPreset(.allVisible, rows: rows)
        let selectable = rows.filter(\.isSelectable)
        model.toggleChecked(selectable[0], extendingRange: false, order: rows)   // turns the first one off, anchor = first
        XCTAssertFalse(model.checked.contains(selectable[0].id))

        model.toggleChecked(selectable[2], extendingRange: true, order: rows)    // that one was on: the range goes off

        XCTAssertFalse(model.checked.contains(selectable[1].id))
        XCTAssertFalse(model.checked.contains(selectable[2].id))
    }

    func testAProtectedRowCannotBeTicked() {
        let (model, rows) = makeModel()
        let locked = rows.first { $0.verdict == .protected }!

        model.toggleChecked(locked, extendingRange: false, order: rows)

        XCTAssertTrue(model.checked.isEmpty)
    }

    func testTheHeaderCheckboxPicksEverythingShownThenClearsIt() {
        let (model, rows) = makeModel()
        let selectable = Set(rows.filter(\.isSelectable).map(\.id))

        model.setAllShown(true, rows: rows)
        XCTAssertEqual(model.checked, selectable)

        model.setAllShown(false, rows: rows)
        XCTAssertTrue(model.checked.isEmpty)
    }

    func testTheHeaderCheckboxLeavesAHiddenSelectionAlone() {
        let (model, rows) = makeModel()
        let hiddenOne = rows[0]
        model.updateSelection(fromTable: [hiddenOne.id])
        let shown = Array(rows.dropFirst())

        model.setAllShown(true, rows: shown)
        model.setAllShown(false, rows: shown)

        XCTAssertEqual(model.checked, [hiddenOne.id], "a row a filter hides keeps its place in the selection")
    }

    func testAPresetReplacesTheSelectionAndAMenuLikeThisPicksTheSharedRows() {
        let (model, rows) = makeModel()

        model.applyPreset(.onlyReview, rows: rows)
        XCTAssertEqual(Set(model.allRows.filter { model.checked.contains($0.id) }.map(\.verdict)), [.review])

        model.select(sharing: .verdict(.safe), among: rows)
        XCTAssertEqual(Set(model.allRows.filter { model.checked.contains($0.id) }.map(\.verdict)), [.safe])
    }

    func testTheSummaryReportsWhatAFilterIsHiding() {
        let (model, rows) = makeModel()
        model.applyPreset(.allVisible, rows: rows)
        let shown = Array(rows.prefix(2))

        let summary = model.selectionSummary(shown: shown)

        XCTAssertEqual(summary.count, rows.filter(\.isSelectable).count)
        XCTAssertEqual(summary.hidden, summary.count - shown.filter(\.isSelectable).count)
    }

    func testEscapeStyleClearingEmptiesTheSelectionAndTheInspector() {
        let (model, rows) = makeModel()
        model.applyPreset(.allVisible, rows: rows)

        model.setSelection([])

        XCTAssertTrue(model.checked.isEmpty)
        XCTAssertNil(model.focusedRowID)
    }

    // MARK: Sections

    func testGroupingByVerdictMakesOrderedSectionsAndCollapsingHidesTheirRows() {
        let (_, rows) = makeModel()

        let items = RepoTableItems.build(rows: rows, sortOrder: [], grouping: .verdict)
        let headers = items.compactMap(\.section).map(\.key.title)
        XCTAssertEqual(headers, ["Safe", "Review", "Protected"].filter { title in
            rows.contains { $0.verdict.label == title }
        })
        XCTAssertEqual(items.count, rows.count + headers.count, "every row appears once, under its header")

        let collapsed = RepoTableItems.build(rows: rows, sortOrder: [], grouping: .verdict, collapsed: ["group:verdict:Safe"])
        XCTAssertEqual(collapsed.compactMap(\.row).count, rows.filter { $0.verdict != .safe }.count)
        XCTAssertEqual(collapsed.compactMap(\.section).first { $0.key.title == "Safe" }?.rows.count,
                       rows.filter { $0.verdict == .safe }.count, "a collapsed section still knows its rows")
    }

    func testUngroupedItemsAreJustTheRowsAndSortingAppliesInsideSections() {
        let (_, rows) = makeModel()

        let flat = RepoTableItems.build(rows: rows, sortOrder: [], grouping: .none)
        XCTAssertEqual(flat.compactMap(\.row).map(\.id), rows.map(\.id))
        XCTAssertTrue(flat.compactMap(\.section).isEmpty)

        let sorted = RepoTableItems.build(rows: rows, sortOrder: [KeyPathComparator(\RepoTableItem.titleSort)], grouping: .verdict)
        for section in sorted.compactMap(\.section) {
            let inSection = sorted.compactMap(\.row).filter { section.rows.map(\.id).contains($0.id) }.map(\.title)
            XCTAssertEqual(inSection, inSection.sorted(), "rows are sorted within their section")
        }
    }

    // MARK: Agents

    private func agentModel() -> AppModel {
        let measured = Fixtures.agentMeasurements
        return AppModel.preview(
            snapshots: [Fixtures.agentSample], sizes: measured.sizes, activity: measured.activity, route: .agents,
            clock: { Fixtures.now })
    }

    func testTheAgentsHeaderCheckboxIncludesOrLeavesOutEveryFinishedWorktreeShown() {
        let model = agentModel()
        let shown = model.visibleAgentRows
        let eligible = model.eligibleAgentRows(shown: shown)
        XCTAssertGreaterThan(eligible.count, 1)
        XCTAssertEqual(model.headerStateForAgents(shown: shown), .all, "finished worktrees start included")

        model.setAllAgentsShown(false, shown: shown)
        XCTAssertEqual(model.headerStateForAgents(shown: shown), .none)
        XCTAssertTrue(model.reclaimableAgentRows.isEmpty)

        model.setAllAgentsShown(true, shown: shown)
        XCTAssertEqual(model.reclaimableAgentRows.count, eligible.count)
    }

    func testShiftClickingAnAgentCheckboxSetsTheRangeAndLockedWorktreesAreSkipped() {
        let model = agentModel()
        let shown = model.visibleAgentRows
        let eligible = model.eligibleAgentRows(shown: shown)
        model.setAllAgentsShown(false, shown: shown)

        model.toggleAgentIncluded(eligible[0], extendingRange: false, order: shown)
        model.toggleAgentIncluded(eligible[1], extendingRange: true, order: shown)

        XCTAssertTrue(model.isAgentIncluded(eligible[0].id))
        XCTAssertTrue(model.isAgentIncluded(eligible[1].id))
        XCTAssertEqual(model.reclaimableAgentRows.count, 2)
        for item in shown where !item.assessment.isReclaimable {
            XCTAssertFalse(model.reclaimableAgentRows.contains { $0.id == item.id }, "a worktree that cannot be reclaimed is never included")
        }
    }

    func testTheAgentsNonePresetAlsoClearsWorktreesAFilterIsHiding() {
        let model = agentModel()
        let shown = Array(model.visibleAgentRows.prefix(1))

        model.applyAgentPreset(.none, shown: shown)

        XCTAssertTrue(model.reclaimableAgentRows.isEmpty)
    }

    func testIncludingLikeThisKeepsOnlyTheMatchingFinishedWorktrees() {
        let model = agentModel()
        let shown = model.visibleAgentRows
        model.includeAgents(sharing: .tool("Nothing Like This"), shown: shown)
        XCTAssertTrue(model.reclaimableAgentRows.isEmpty)

        model.includeAgents(sharing: .tool("Claude Code"), shown: shown)
        XCTAssertEqual(model.reclaimableAgentRows.count, model.eligibleAgentRows(shown: shown).count)
    }

    /// Snapshots of the real window with the new selection controls. Only runs when `LOPPER_SNAPSHOT_DIR` is set.
    func testWriteSnapshotsOfTheSelectionControls() throws {
        guard let directory = ProcessInfo.processInfo.environment["LOPPER_SNAPSHOT_DIR"] else {
            throw XCTSkip("set LOPPER_SNAPSHOT_DIR to write snapshots")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let measured = Fixtures.agentMeasurements
        let model = AppModel.preview(
            snapshots: [Fixtures.agentSample, Fixtures.sample], sizes: measured.sizes, activity: measured.activity,
            route: .repo(Fixtures.root.path), clock: { Fixtures.now })
        model.showInspector = false
        let rows = model.visibleRows(forRepo: Fixtures.root.path)
        func snap(_ name: String, route: Route, prepare: () -> Void) throws {
            model.route = route
            prepare()
            let controller = NSHostingController(rootView: RootView().environment(model))
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(NSSize(width: 1100, height: 640))
            window.appearance = NSAppearance(named: .darkAqua)
            window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))
            }
            window.close()
        }
        try snap("selection-flat", route: .repo(Fixtures.root.path)) {
            model.repoGrouping = .none
            model.applyPreset(.onlyReview, rows: rows)
        }
        try snap("selection-grouped", route: .repo(Fixtures.root.path)) {
            model.repoGrouping = .verdict
            model.setSelection(Set(rows.filter { $0.verdict == .safe }.map(\.id)))
        }
        try snap("selection-agents", route: .agents) {
            model.applyAgentPreset(.olderThan30Days, shown: model.visibleAgentRows)
        }
    }
}

