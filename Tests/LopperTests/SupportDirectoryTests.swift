import XCTest
@testable import Lopper

final class SupportDirectoryTests: XCTestCase {
    func testTheOverrideRedirectsEverythingLopperStores() {
        let dir = LopperSupport.directory(environment: ["LOPPER_SUPPORT_DIR": "/tmp/lopper-throwaway"])

        XCTAssertEqual(dir.path, "/tmp/lopper-throwaway")
    }

    func testWithoutAnOverrideItIsLopperInApplicationSupport() {
        let dir = LopperSupport.directory(environment: [:])

        XCTAssertEqual(dir.lastPathComponent, "Lopper")
        XCTAssertEqual(dir.deletingLastPathComponent().lastPathComponent, "Application Support")
    }

    func testAnEmptyOrRelativeOverrideIsIgnoredSoNothingLandsInTheWorkingDirectory() {
        XCTAssertEqual(LopperSupport.directory(environment: ["LOPPER_SUPPORT_DIR": ""]).lastPathComponent, "Lopper")
        XCTAssertEqual(LopperSupport.directory(environment: ["LOPPER_SUPPORT_DIR": "relative/path"]).lastPathComponent, "Lopper")
    }

    func testTheUndoLogLivesInsideTheSupportDirectory() {
        XCTAssertEqual(UndoLog.url(in: URL(fileURLWithPath: "/x/Lopper")).path, "/x/Lopper/undo-log.jsonl")
    }
}
