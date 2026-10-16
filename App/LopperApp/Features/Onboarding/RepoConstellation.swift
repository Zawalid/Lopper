import SwiftUI

/// Your repositories as stars: one appears for each repository as it is read, bigger and brighter where there is
/// more to reclaim, joined to its neighbours by faint lines. It is the first scan's own picture, made from the
/// person's data, and nothing like the welcome screen's graph.
struct RepoConstellation: View {
    struct Item: Identifiable, Equatable {
        let id: String
        /// How much there is to reclaim here, in any unit; only the proportions matter.
        let weight: Double
    }

    let items: [Item]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @State private var appearedAt: [String: Date] = [:]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || activeState == .inactive)) { timeline in
            Canvas { context, size in
                // A window in the background does not animate, so it shows every star at once.
                draw(&context, size: size, now: timeline.date, still: reduceMotion || activeState == .inactive)
            }
        }
        .onChange(of: items, initial: true) { _, new in
            for item in new where appearedAt[item.id] == nil { appearedAt[item.id] = Date() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(items.count) repositories")
    }

    /// Golden-angle spiral: evenly spread, never overlapping, and the same for the same count every time.
    private func position(_ index: Int, size: CGSize) -> CGPoint {
        let angle = Double(index) * 2.399963
        let spread = min(size.width, size.height) * 0.052
        let radius = spread * sqrt(Double(index) + 0.8)
        return CGPoint(x: size.width / 2 + CGFloat(cos(angle) * radius), y: size.height / 2 + CGFloat(sin(angle) * radius))
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, now: Date, still: Bool) {
        let mint = Color(red: 0.55, green: 0.95, blue: 0.80)
        let largest = max(items.map(\.weight).max() ?? 1, 1)
        let points = items.indices.map { position($0, size: size) }

        // Lines first, so the stars sit on top. Each star joins the two nearest ones that appeared before it.
        for index in items.indices where index > 0 {
            let age = still ? 1 : min(1, now.timeIntervalSince(appearedAt[items[index].id] ?? now) / 0.8)
            guard age > 0 else { continue }
            let nearest = (0..<index)
                .sorted { distance(points[$0], points[index]) < distance(points[$1], points[index]) }
                .prefix(2)
            for other in nearest {
                var line = Path()
                line.move(to: points[index])
                line.addLine(to: points[other])
                context.stroke(line, with: .color(mint.opacity(0.14 * age)), lineWidth: 1)
            }
        }

        for (index, item) in items.enumerated() {
            let age = still ? 1 : min(1, now.timeIntervalSince(appearedAt[item.id] ?? now) / 0.6)
            guard age > 0 else { continue }
            let eased = age * age * (3 - 2 * age)
            let share = item.weight / largest
            let radius = CGFloat(2.2 + 4.8 * sqrt(share)) * CGFloat(eased)
            let bright = item.weight > 0
            let color: Color = bright ? mint : .white.opacity(0.55)
            let center = points[index]
            // A ring that spreads out from a star as it appears.
            if age < 1 {
                let ring = radius * 3 + CGFloat(age) * 14
                context.stroke(
                    Path(ellipseIn: CGRect(x: center.x - ring, y: center.y - ring, width: ring * 2, height: ring * 2)),
                    with: .color(color.opacity((1 - age) * 0.5)), lineWidth: 1.2)
            }
            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                layer.fill(
                    Path(ellipseIn: CGRect(x: center.x - radius * 3.2, y: center.y - radius * 3.2, width: radius * 6.4, height: radius * 6.4)),
                    with: .color(color.opacity(bright ? 0.16 : 0.06)))
                layer.fill(
                    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(color.opacity(bright ? 0.95 : 0.55)))
            }
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
