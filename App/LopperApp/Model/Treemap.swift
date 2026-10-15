import CoreGraphics
import Foundation

/// A squarified treemap: rectangles whose areas are proportional to the values and that stay close to square,
/// so a big folder reads as a big block and a small one is still findable.
enum Treemap {
    struct Cell<ID: Hashable>: Equatable where ID: Equatable {
        let id: ID
        let rect: CGRect
        let value: Double
    }

    static func layout<ID: Hashable>(_ items: [(ID, Double)], in bounds: CGRect) -> [Cell<ID>] {
        let positive = items.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        guard !positive.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }
        let total = positive.reduce(0) { $0 + $1.1 }
        let scale = Double(bounds.width * bounds.height) / total
        // Areas in points, same order as `positive`.
        let areas = positive.map { $0.1 * scale }

        var cells: [Cell<ID>] = []
        var remaining = bounds
        var index = 0
        while index < positive.count {
            let shortSide = Double(min(remaining.width, remaining.height))
            var row: [Int] = [index]
            var best = worstRatio(areas: [areas[index]], side: shortSide)
            var next = index + 1
            while next < positive.count {
                let candidate = row + [next]
                let ratio = worstRatio(areas: candidate.map { areas[$0] }, side: shortSide)
                if ratio > best { break }
                best = ratio
                row = candidate
                next += 1
            }
            remaining = place(row: row, areas: areas, items: positive, in: remaining, into: &cells)
            index = next
        }
        return cells
    }

    private static func worstRatio(areas: [Double], side: Double) -> Double {
        let sum = areas.reduce(0, +)
        guard let maxArea = areas.max(), let minArea = areas.min(), sum > 0, side > 0 else { return .infinity }
        let sideSquared = side * side
        return max(sideSquared * maxArea / (sum * sum), sum * sum / (sideSquared * minArea))
    }

    /// Lays one row along the shorter side and returns the rectangle that is left.
    private static func place<ID: Hashable>(
        row: [Int], areas: [Double], items: [(ID, Double)], in rect: CGRect, into cells: inout [Cell<ID>]
    ) -> CGRect {
        let rowArea = row.reduce(0) { $0 + areas[$1] }
        let horizontal = rect.width >= rect.height   // the row is a column on the left when the rect is wide
        if horizontal {
            let width = CGFloat(rowArea) / rect.height
            var y = rect.minY
            for (position, index) in row.enumerated() {
                let isLast = position == row.count - 1
                let height = isLast ? rect.maxY - y : CGFloat(areas[index]) / width
                cells.append(Cell(id: items[index].0, rect: CGRect(x: rect.minX, y: y, width: width, height: height),
                                  value: items[index].1))
                y += height
            }
            return CGRect(x: rect.minX + width, y: rect.minY, width: max(0, rect.width - width), height: rect.height)
        } else {
            let height = CGFloat(rowArea) / rect.width
            var x = rect.minX
            for (position, index) in row.enumerated() {
                let isLast = position == row.count - 1
                let width = isLast ? rect.maxX - x : CGFloat(areas[index]) / height
                cells.append(Cell(id: items[index].0, rect: CGRect(x: x, y: rect.minY, width: width, height: height),
                                  value: items[index].1))
                x += width
            }
            return CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: max(0, rect.height - height))
        }
    }
}
