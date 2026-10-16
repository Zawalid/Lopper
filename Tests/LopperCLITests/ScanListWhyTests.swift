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
}
