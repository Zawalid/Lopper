import ArgumentParser
import XCTest
@testable import LopperCLI

final class ScanListWhyTests: XCTestCase {
    func testScanSummarizesEachRepositoryAndTheTotals() async throws {
        let harness = try Harness()
        let result = try await harness.run(["scan"])

        XCTAssertTrue(result.out.contains("repo"), result.out)
        XCTAssertTrue(result.out.contains("1 safe to remove, 1 need a look, 1 protected"), result.out)
        XCTAssertTrue(result.out.contains("lop clean"), result.out)
    }

    func testScanAsJSONHasAVersionedSchema() async throws {
        let harness = try Harness()
        let result = try await harness.run(["scan", "--json"])

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any])
        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual(object["safe"] as? Int, 1)
        XCTAssertEqual(object["review"] as? Int, 1)
        XCTAssertEqual((object["repositories"] as? [[String: Any]])?.count, 1)
    }

    func testListShowsVerdictsSafeFirstWithEvidence() async throws {
        let harness = try Harness()
        let result = try await harness.run(["list"])

        let lines = result.out.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("SAFE"), result.out)
        XCTAssertTrue(lines[0].contains("done"), result.out)
        XCTAssertTrue(lines[1].hasPrefix("REVIEW"), result.out)
        XCTAssertTrue(lines[1].contains("wip"), result.out)
        XCTAssertTrue(result.out.contains("PROTECTED"), result.out)
    }

    func testListFiltersByVerdictAndText() async throws {
        let harness = try Harness()

        let safeOnly = try await harness.run(["list", "--safe"])
        XCTAssertTrue(safeOnly.out.contains("done"))
        XCTAssertFalse(safeOnly.out.contains("wip"))

        let byText = try await harness.run(["list", "wi"])
        XCTAssertTrue(byText.out.contains("wip"))
        XCTAssertFalse(byText.out.contains("done"))
    }

    func testListJSONCarriesEveryRowWithItsEligibility() async throws {
        let harness = try Harness()
        let result = try await harness.run(["list", "--json"])

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(object["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["title"] as? String }, ["done", "wip", "main"])
        XCTAssertEqual(rows.map { $0["bulkEligible"] as? Bool }, [true, false, false])
        XCTAssertEqual(rows.map { $0["verdict"] as? String }, ["safe", "review", "protected"])
    }

    func testWhyExplainsOneItem() async throws {
        let harness = try Harness()
        let result = try await harness.run(["why", "done"])

        XCTAssertTrue(result.out.contains("done"), result.out)
        XCTAssertTrue(result.out.contains("Verdict"), result.out)
        XCTAssertTrue(result.out.contains("SAFE"), result.out)
        XCTAssertTrue(result.out.contains("Evidence"), result.out)
    }

    func testWhyRefusesAnUnknownName() async throws {
        let harness = try Harness()
        do {
            try await harness.run(["why", "does-not-exist"])
            XCTFail("expected an error")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("Nothing matches"), error.message)
        }
    }

    func testCommandsNeedAFolderToScan() async throws {
        let harness = try Harness(foldersConfigured: false)
        do {
            try await harness.run(["scan"])
            XCTFail("expected an error")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("lop folders add"), error.message)
        }
    }
    func testRiskListsWorkThatExistsOnlyOnThisMac() async throws {
        let harness = try Harness()
        let result = try await harness.run(["risk"])

        XCTAssertTrue(result.out.contains("exist only on this Mac"), result.out)
        XCTAssertTrue(result.out.contains("wip"), result.out)
        XCTAssertTrue(result.out.contains("1 commit not on any remote"), result.out)
        XCTAssertTrue(result.out.contains("push -u origin wip"), result.out)
        XCTAssertFalse(result.out.contains("done  "), "a merged branch holds nothing that is only here")
    }

    func testRiskJSONCarriesTheItems() async throws {
        let harness = try Harness()
        let result = try await harness.run(["risk", "--json"])

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any])
        XCTAssertEqual(object["total"] as? Int, 1)
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["kind"] as? String, "unpushedCommits")
        XCTAssertEqual(items.first?["title"] as? String, "wip")
        XCTAssertEqual(items.first?["count"] as? Int, 1)
    }

    func testRiskSaysSoWhenEverythingIsBackedUp() async throws {
        let harness = try Harness()
        try harness.repo.git("push", "-u", "origin", "wip")

        let result = try await harness.run(["risk"])

        XCTAssertTrue(result.out.contains("backed up or merged"), result.out)
    }
    func testDiagnosticsPrintsAReportWithoutNamesByDefault() async throws {
        let harness = try Harness()
        let result = try await harness.run(["diagnostics"])

        XCTAssertTrue(result.out.contains("Lopper diagnostics"), result.out)
        XCTAssertTrue(result.out.contains("Names: left out"), result.out)
        XCTAssertTrue(result.out.contains("lop "), result.out)
        XCTAssertTrue(result.out.contains("1 repositories, 0 failed"), result.out)
        XCTAssertFalse(result.out.contains(harness.repo.sandbox.path), "no folder paths: \(result.out)")
        XCTAssertFalse(result.out.contains("wip"), "branch names are hidden: \(result.out)")
    }

    func testDiagnosticsCanIncludeNamesAndEmitJSON() async throws {
        let harness = try Harness()
        let result = try await harness.run(["diagnostics", "--include-names", "--json"])

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any])
        let text = try XCTUnwrap(object["report"] as? String)
        XCTAssertTrue(text.contains("Names: included"), text)
        XCTAssertEqual(object["namesIncluded"] as? String, "true")
    }

    func testDiagnosticsKeepsWorkingWithNoFolders() async throws {
        let harness = try Harness(foldersConfigured: false)
        let result = try await harness.run(["diagnostics"])
        XCTAssertTrue(result.out.contains("none recorded"), result.out)
    }
}
