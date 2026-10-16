import XCTest

final class SmokeTests: XCTestCase {
    func testTestsRunInsideTheLopperAppBundle() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.zawalid.lopper")
    }
}
