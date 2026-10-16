import ArgumentParser
import XCTest
@testable import LopperCLI

final class CleanUndoTests: XCTestCase {
    func testDryRunShowsThePlanAndRemovesNothing() async throws {
        let harness = try Harness()
        let result = try await harness.run(["clean", "--dry-run"])

        XCTAssertTrue(result.out.contains("This will remove 1 item"), result.out)
        XCTAssertTrue(result.out.contains("done"), result.out)
        XCTAssertTrue(result.out.contains("Dry run: nothing was removed."), result.out)
        XCTAssertTrue(try harness.branches().contains("done"))
    }

    func testRefusesToRemoveWithoutConfirmationWhenNotInATerminal() async throws {
        let harness = try Harness()
        do {
            try await harness.run(["clean"])
            XCTFail("expected a refusal")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("--yes"), error.message)
        }
        XCTAssertTrue(try harness.branches().contains("done"))
    }

    func testAnswerNoRemovesNothing() async throws {
        let harness = try Harness()
        let result = try await harness.run(["clean"], interactive: true, answers: ["n"])

        XCTAssertTrue(result.out.contains("Nothing was removed."), result.out)
        XCTAssertTrue(try harness.branches().contains("done"))
    }

    func testAnswerYesRemovesOnlyTheSafeItemAndPointsToUndo() async throws {
        let harness = try Harness()
        let result = try await harness.run(["clean"], interactive: true, answers: ["y"])

        XCTAssertTrue(result.out.contains("removed  done"), result.out)
        XCTAssertTrue(result.out.contains("lop undo --last"), result.out)
        let branches = try harness.branches()
        XCTAssertFalse(branches.contains("done"))
        XCTAssertTrue(branches.contains("wip"), "work that is not merged must stay")
        XCTAssertTrue(branches.contains("main"))
    }

    func testIncludeReviewNeedsAName() async throws {
        let harness = try Harness()
        do {
            try await harness.run(["clean", "--include-review", "--yes"])
            XCTFail("expected a refusal")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("--include-review"), error.message)
        }
        XCTAssertTrue(try harness.branches().contains("wip"))
    }

    func testUndoLastBringsTheCleanupBack() async throws {
        let harness = try Harness()
        let tipBefore = try harness.repo.sha("done")
        try await harness.run(["clean", "--yes"])
        XCTAssertFalse(try harness.branches().contains("done"))

        let result = try await harness.run(["undo", "--last"])

        XCTAssertTrue(result.out.contains("restored  done"), result.out)
        XCTAssertTrue(try harness.branches().contains("done"))
        XCTAssertEqual(try harness.repo.sha("done"), tipBefore, "a branch comes back at its exact commit")
    }

    func testRemovingAReviewItemByNameCanBeUndoneByItsId() async throws {
        let harness = try Harness()
        let tipBefore = try harness.repo.sha("wip")
        try await harness.run(["clean", "wip", "--include-review", "--yes"])
        XCTAssertFalse(try harness.branches().contains("wip"))

        let json = try await harness.run(["history", "--json"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any])
        let entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        let id = try XCTUnwrap(entries.first?["id"] as? String)

        try await harness.run(["undo", String(id.prefix(8))])

        XCTAssertTrue(try harness.branches().contains("wip"))
        XCTAssertEqual(try harness.repo.sha("wip"), tipBefore)
    }

    func testHistoryListsEntriesWithDaysLeft() async throws {
        let harness = try Harness()
        try await harness.run(["clean", "--yes"])

        let result = try await harness.run(["history"])

        XCTAssertTrue(result.out.contains("done"), result.out)
        XCTAssertTrue(result.out.contains("branch"), result.out)
        XCTAssertTrue(result.out.contains("d left"), result.out)
    }

    func testHistoryWhenNothingWasRemoved() async throws {
        let harness = try Harness()
        let result = try await harness.run(["history"])
        XCTAssertTrue(result.out.contains("Nothing has been removed yet."), result.out)
    }

    func testUndoRejectsAnUnknownId() async throws {
        let harness = try Harness()
        do {
            try await harness.run(["undo", "deadbeef"])
            XCTFail("expected an error")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("No entry starts with"), error.message)
        }
    }
}
