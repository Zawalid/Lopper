import XCTest
@testable import LopperApp

final class TagListTests: XCTestCase {
    func testAddingTrimsIgnoresEmptyAndDuplicatesAndKeepsOrder() {
        var tags = ["main", "develop"]
        tags = TagList.adding("  release/*  ", to: tags)
        XCTAssertEqual(tags, ["main", "develop", "release/*"])

        XCTAssertEqual(TagList.adding("   ", to: tags), tags)
        XCTAssertEqual(TagList.adding("", to: tags), tags)
        XCTAssertEqual(TagList.adding("main", to: tags), tags)
    }

    func testRemovingATagKeepsTheOthersAndIgnoresUnknownTags() {
        let tags = ["a", "b", "c"]
        XCTAssertEqual(TagList.removing("b", from: tags), ["a", "c"])
        XCTAssertEqual(TagList.removing("zzz", from: tags), tags)
    }

    func testCommaSeparatedInputAddsSeveralTagsAtOnce() {
        XCTAssertEqual(
            TagList.adding("hotfix/*, staging ,main", to: ["main"]),
            ["main", "hotfix/*", "staging"])
    }
}
