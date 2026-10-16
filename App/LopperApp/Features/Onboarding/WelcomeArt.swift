import SwiftUI

/// A branch tree that grows, then loses its stale branches one by one: the whole product in one picture.
/// Kept branches stay green and solid, stale ones are grey and dashed until a small flash cuts them away.
struct WelcomeArt: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period: Double = 11
    private static let branchCount = 6
    private static let stale: Set<Int> = [1, 3, 4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let seconds = reduceMotion
                ? 8
                : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
            Canvas { context, size in
                draw(context: context, size: size, time: seconds)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A branch tree losing its stale branches")
    }

    // MARK: Geometry

    private struct Branch {
        let index: Int
        let start: CGPoint
        let end: CGPoint
        let control1: CGPoint
        let control2: CGPoint

        var path: Path {
            Path { path in
                path.move(to: start)
                path.addCurve(to: end, control1: control1, control2: control2)
            }
        }
    }

    private func branches(in size: CGSize) -> [Branch] {
        let trunkX = size.width / 2
        let bottom = size.height - 26
        let spacing = (size.height - 90) / CGFloat(Self.branchCount)
        return (0..<Self.branchCount).map { index in
            let direction: CGFloat = index.isMultiple(of: 2) ? -1 : 1
            let reach = (size.width * 0.28) + CGFloat(index % 3) * 18
            let y = bottom - 28 - CGFloat(index) * spacing
            let start = CGPoint(x: trunkX, y: y)
            let end = CGPoint(x: trunkX + direction * reach, y: y - 46 - CGFloat(index % 2) * 10)
            return Branch(
                index: index, start: start, end: end,
                control1: CGPoint(x: trunkX, y: y - 30),
                control2: CGPoint(x: trunkX + direction * reach * 0.45, y: end.y))
        }
    }

    // MARK: Timeline

    private func ease(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// How much of a branch is drawn: it grows in, holds, and a stale one is cut at its own moment.
    private func progress(of index: Int, at time: Double) -> Double {
        let grown = ease((time - 0.5 - Double(index) * 0.22) / 0.9)
        guard Self.stale.contains(index) else { return grown }
        let order = Self.stale.sorted().firstIndex(of: index) ?? 0
        let cut = 4.2 + Double(order) * 1.4
        return grown * (1 - ease((time - cut) / 0.7))
    }

    private func cutTime(of index: Int) -> Double? {
        guard Self.stale.contains(index), let order = Self.stale.sorted().firstIndex(of: index) else { return nil }
        return 4.2 + Double(order) * 1.4
    }

    private func draw(context: GraphicsContext, size: CGSize, time: Double) {
        // Everything fades out together at the end of the loop so the restart is not a jump.
        let fade = 1 - ease((time - 9.8) / 1.0)
        var context = context
        context.opacity = fade

        let trunkX = size.width / 2
        let bottom = size.height - 26
        let top: CGFloat = 26
        let trunkGrow = ease((time - 0.1) / 0.8)
        let trunk = Path { path in
            path.move(to: CGPoint(x: trunkX, y: bottom))
            path.addLine(to: CGPoint(x: trunkX, y: bottom - (bottom - top) * trunkGrow))
        }
        context.stroke(trunk, with: .color(.primary.opacity(0.55)), style: StrokeStyle(lineWidth: 4, lineCap: .round))

        for branch in branches(in: size) {
            let amount = progress(of: branch.index, at: time)
            let isStale = Self.stale.contains(branch.index)
            if amount > 0.001 {
                let color: Color = isStale ? .secondary : .green
                let style = isStale
                    ? StrokeStyle(lineWidth: 3, lineCap: .round, dash: [5, 6])
                    : StrokeStyle(lineWidth: 3.5, lineCap: .round)
                context.stroke(
                    branch.path.trimmedPath(from: 0, to: amount),
                    with: .color(color.opacity(isStale ? 0.8 : 1)), style: style)
                if amount > 0.98 {
                    let node = CGRect(x: branch.end.x - 6, y: branch.end.y - 6, width: 12, height: 12)
                    context.fill(Path(ellipseIn: node), with: .color(color.opacity(isStale ? 0.7 : 1)))
                }
            }
            // The flash where a stale branch is cut.
            if let cut = cutTime(of: branch.index), time > cut, time < cut + 0.6 {
                let phase = (time - cut) / 0.6
                let radius = 6 + 24 * ease(phase)
                let ring = Path(ellipseIn: CGRect(
                    x: branch.start.x - radius, y: branch.start.y - radius, width: radius * 2, height: radius * 2))
                context.stroke(ring, with: .color(.orange.opacity(1 - phase)), lineWidth: 2.5)
                for tick in 0..<6 {
                    let angle = Double(tick) / 6 * 2 * .pi + 0.3
                    let inner = radius * 0.5, outer = radius * 0.9
                    let spark = Path { path in
                        path.move(to: CGPoint(
                            x: branch.start.x + CGFloat(cos(angle)) * inner,
                            y: branch.start.y + CGFloat(sin(angle)) * inner))
                        path.addLine(to: CGPoint(
                            x: branch.start.x + CGFloat(cos(angle)) * outer,
                            y: branch.start.y + CGFloat(sin(angle)) * outer))
                    }
                    context.stroke(spark, with: .color(.orange.opacity(1 - phase)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
        }

        // Commits along the trunk.
        for step in 0..<8 {
            let y = bottom - CGFloat(step) * (bottom - top) / 7.5
            if (bottom - y) / (bottom - top) <= trunkGrow {
                let dot = CGRect(x: trunkX - 4.5, y: y - 4.5, width: 9, height: 9)
                context.fill(Path(ellipseIn: dot), with: .color(.primary.opacity(0.85)))
            }
        }
    }
}
