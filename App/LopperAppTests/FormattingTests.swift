import XCTest
import Lopper
@testable import LopperApp

final class FormattingTests: XCTestCase {
    func testAgeIsCompact() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func age(_ days: Int) -> String { AgeFormat.short(from: now.addingTimeInterval(-Double(days) * 86_400), to: now) }
        XCTAssertEqual(age(0), "today")
        XCTAssertEqual(age(5), "5d")
        XCTAssertEqual(age(59), "59d")
        XCTAssertEqual(age(90), "3mo")
        XCTAssertEqual(age(800), "2y")
    }

    func testPluralAndSize() {
        XCTAssertEqual(Plural.count(1, "branch", "branches"), "1 branch")
        XCTAssertEqual(Plural.count(3, "branch", "branches"), "3 branches")
        XCTAssertEqual(Plural.count(2, "worktree"), "2 worktrees")
        XCTAssertTrue(SizeFormat.string(3_070_000_000).hasPrefix("3"))
    }
}
