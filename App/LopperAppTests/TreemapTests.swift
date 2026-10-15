import XCTest
@testable import LopperApp

final class TreemapTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)

    private func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    func testEveryItemGetsAnAreaProportionalToItsValue() {
        let items = [("a", 600.0), ("b", 300.0), ("c", 100.0)]

        let cells = Treemap.layout(items, in: bounds)

        XCTAssertEqual(cells.count, 3)
        let total = area(bounds)
        for (id, value) in items {
            let cell = cells.first { $0.id == id }!
            XCTAssertEqual(area(cell.rect) / total, value / 1_000, accuracy: 0.001, id)
        }
    }

    func testCellsStayInsideTheBoundsAndDoNotOverlap() {
        let items = (1...12).map { ("n\($0)", Double($0 * $0)) }

        let cells = Treemap.layout(items, in: bounds)

        for cell in cells {
            XCTAssertTrue(bounds.insetBy(dx: -0.001, dy: -0.001).contains(cell.rect), "\(cell.id) \(cell.rect)")
        }
        for (index, first) in cells.enumerated() {
            for second in cells[(index + 1)...] {
                let overlap = first.rect.intersection(second.rect)
                XCTAssertLessThan(overlap.isNull ? 0 : area(overlap), 0.01, "\(first.id) overlaps \(second.id)")
            }
        }
    }

    func testTheCellsFillTheWholeRectangle() {
        let items = [("a", 5.0), ("b", 3.0), ("c", 2.0), ("d", 1.0)]

        let cells = Treemap.layout(items, in: bounds)

        XCTAssertEqual(cells.reduce(0) { $0 + area($1.rect) }, area(bounds), accuracy: 0.5)
    }

    func testBiggestFirstAndSquarishCells() {
        let items = [("small", 1.0), ("big", 50.0), ("mid", 10.0)]

        let cells = Treemap.layout(items, in: bounds)

        XCTAssertEqual(cells.first?.id, "big")
        for cell in cells.filter({ area($0.rect) > 500 }) {
            let ratio = max(cell.rect.width, cell.rect.height) / max(1, min(cell.rect.width, cell.rect.height))
            XCTAssertLessThan(ratio, 6, "\(cell.id) is a sliver: \(cell.rect)")
        }
    }

    func testEmptyZeroAndSingleInputs() {
        XCTAssertTrue(Treemap.layout([(String, Double)](), in: bounds).isEmpty)
        XCTAssertTrue(Treemap.layout([("a", 0.0)], in: bounds).isEmpty, "a zero value has no area")
        let single = Treemap.layout([("a", 7.0)], in: bounds)
        XCTAssertEqual(single.map(\.rect), [bounds])
        XCTAssertTrue(Treemap.layout([("a", 1.0)], in: CGRect(x: 0, y: 0, width: 0, height: 10)).isEmpty)
    }
}
