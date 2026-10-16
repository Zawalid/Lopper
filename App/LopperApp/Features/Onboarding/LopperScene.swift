import SwiftUI
import Lopper

/// The welcome picture: a living git graph. Commits flow up the trunk as light, stale branches are cut by a pair
/// of scissors one by one and dissolve into embers, and what is left glows brighter. It follows the pointer
/// a little, and holds a finished frame when motion is reduced.
struct LopperScene: View {
    /// Quieter: no labels and no counter, for behind other screens.
    var compact = false
    /// How strongly the picture is drawn, 0...1. Behind a panel it is turned down so the words win.
    var intensity: Double = 1
    /// A fixed moment in the loop, for tests and snapshots.
    var fixedTime: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState
    @State private var pointer: CGPoint?
    private let graph = SceneGraph.make()

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || fixedTime != nil || activeState == .inactive)) { timeline in
                let time = currentTime(timeline.date)
                ZStack(alignment: .bottomTrailing) {
                    Canvas { context, size in
                        var context = context
                        SceneRenderer(
                            graph: graph, size: size, time: time, pointer: pointer, compact: compact,
                            intensity: intensity
                        ).draw(&context)
                    }
                    if !compact { FreedCounter(time: time).padding(28) }
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    pointer = CGPoint(
                        x: (location.x / max(proxy.size.width, 1) - 0.5) * 2,
                        y: (location.y / max(proxy.size.height, 1) - 0.5) * 2)
                case .ended:
                    pointer = nil
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("A git graph where stale branches are cut away and the rest glows brighter")
    }

    private func currentTime(_ date: Date) -> Double {
        if let fixedTime { return fixedTime }
        if reduceMotion { return SceneTimeline.stillFrame }
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: SceneTimeline.period)
    }
}

private struct FreedCounter: View {
    let time: Double

    var body: some View {
        let freed = SceneTimeline.freedGB(at: time)
        let step = Int(freed * 10)
        VStack(alignment: .trailing, spacing: 0) {
            Text(SizeFormat.string(Int64(freed * 1_000_000_000)))
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: freed))
                .animation(.snappy(duration: 0.3), value: step)
            Text("lighter")
                .font(.system(size: 13, weight: .medium))
                .textCase(.uppercase)
                .tracking(2)
                .foregroundStyle(.white.opacity(0.55))
        }
        .foregroundStyle(
            LinearGradient(colors: [.white, Color(red: 0.55, green: 0.95, blue: 0.8)], startPoint: .top, endPoint: .bottom))
        .opacity(freed > 0.01 ? min(1, freed * 2) : 0)
        .shadow(color: Color(red: 0.3, green: 0.9, blue: 0.7).opacity(0.35), radius: 14)
        .accessibilityHidden(true)
    }
}

// MARK: Drawing

private struct SceneRenderer {
    let graph: SceneGraph
    let size: CGSize
    let time: Double
    let pointer: CGPoint?
    let compact: Bool
    let intensity: Double

    private let ink = Color(red: 0.045, green: 0.055, blue: 0.09)
    private let keptColor = Color(red: 0.42, green: 0.95, blue: 0.78)
    private let activeColor = Color(red: 0.45, green: 0.72, blue: 1.0)
    private let staleColor = Color(red: 0.78, green: 0.70, blue: 0.60)
    private let trunkColor = Color(red: 0.82, green: 0.90, blue: 1.0)
    private let ember = Color(red: 1.0, green: 0.72, blue: 0.30)

    private var width: CGFloat { size.width }
    private var height: CGFloat { size.height }
    private var parallax: CGSize {
        guard let pointer else { return .zero }
        return CGSize(width: -pointer.x * 14, height: -pointer.y * 9)
    }

    /// Everything glows brighter once the last stale branch is gone.
    private var gain: Double {
        let last = SceneTimeline.cutTimes.last ?? 0
        return 1 + 0.45 * SceneTimeline.ease((time - last) / 1.4)
    }

    /// The whole picture fades out at the end of the loop and in at the start, so the restart is not a jump.
    private var master: Double {
        let fadeIn = SceneTimeline.ease(time / 0.6)
        let fadeOut = 1 - SceneTimeline.ease((time - (SceneTimeline.period - 1.0)) / 0.9)
        return min(fadeIn, fadeOut)
    }

    // MARK: Geometry

    private func trunkPoint(_ s: Double) -> CGPoint {
        let x = width * 0.72 + CGFloat(sin(s * 3.1 + time * 0.5)) * width * 0.011 + CGFloat(s - 0.5) * width * 0.02
        let y = height * (1.06 - 1.12 * CGFloat(s))
        return CGPoint(x: x, y: y)
    }

    private func point(on points: [CGPoint], at u: Double) -> CGPoint {
        guard points.count > 1 else { return points.first ?? .zero }
        let scaled = min(max(u, 0), 1) * Double(points.count - 1)
        let index = min(Int(scaled), points.count - 2)
        let fraction = CGFloat(scaled - Double(index))
        let a = points[index], b = points[index + 1]
        return CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
    }

    /// The sampled curve of every branch, parents before children.
    private func curves() -> [[CGPoint]] {
        var all: [[CGPoint]] = []
        for (index, branch) in graph.branches.enumerated() {
            let origin: CGPoint
            if let parent = branch.parent {
                origin = point(on: all[parent], at: branch.attach)
            } else {
                origin = trunkPoint(branch.attach)
            }
            let dx = CGFloat(branch.side) * CGFloat(branch.reach) * width
            let dy = -CGFloat(branch.rise) * height
            let p1 = CGPoint(x: origin.x + dx * 0.08, y: origin.y + dy * 0.75)
            let p2 = CGPoint(x: origin.x + dx * 0.5, y: origin.y + dy * 1.05)
            let p3 = CGPoint(x: origin.x + dx, y: origin.y + dy)
            var points: [CGPoint] = []
            for step in 0...26 {
                let u = CGFloat(step) / 26
                let inverse = 1 - u
                let x = inverse * inverse * inverse * origin.x + 3 * inverse * inverse * u * p1.x
                    + 3 * inverse * u * u * p2.x + u * u * u * p3.x
                let y = inverse * inverse * inverse * origin.y + 3 * inverse * inverse * u * p1.y
                    + 3 * inverse * u * u * p2.y + u * u * u * p3.y
                let sway = CGFloat(sin(Double(u) * 4 + time * 0.8 + Double(index))) * width * 0.0035 * u
                points.append(CGPoint(x: x + sway, y: y))
            }
            all.append(points)
        }
        return all
    }

    private func path(_ points: [CGPoint], from start: Double = 0, to end: Double = 1) -> Path {
        let count = points.count - 1
        let first = Int(start * Double(count)), last = Int(ceil(end * Double(count)))
        guard last > first else { return Path() }
        return Path { path in
            path.move(to: point(on: points, at: start))
            for index in (first + 1)..<last where Double(index) / Double(count) > start && Double(index) / Double(count) < end {
                path.addLine(to: points[index])
            }
            path.addLine(to: point(on: points, at: end))
        }
    }

    // MARK: Drawing

    func draw(_ context: inout GraphicsContext) {
        let curves = self.curves()
        context.opacity = master * intensity
        drawBackground(&context)

        context.translateBy(x: parallax.width, y: parallax.height)
        drawTrunk(&context)
        for (index, branch) in graph.branches.enumerated() {
            drawBranch(&context, index: index, branch: branch, points: curves[index])
        }
        for (index, branch) in graph.branches.enumerated() where branch.kind != .stale || cutTime(of: index) == nil {
            drawPulses(&context, index: index, branch: branch, points: curves[index])
        }
        drawTrunkNodes(&context)
        if !compact { drawLabels(&context, curves: curves) }
        for (position, index) in SceneTimeline.cutOrder.enumerated() {
            drawCut(&context, position: position, branchIndex: index, points: curves[index])
        }
        drawBloom(&context)
        drawScissors(&context, curves: curves)
    }

    private func cutTime(of branchIndex: Int) -> Double? {
        guard let position = SceneTimeline.cutOrder.firstIndex(of: branchIndex) else { return nil }
        let cut = SceneTimeline.cutTimes[position]
        return time >= cut ? cut : nil
    }

    private func color(for kind: SceneGraph.Kind) -> Color {
        switch kind {
        case .kept: keptColor
        case .active: activeColor
        case .stale: staleColor
        }
    }

    /// A soft glow built from three strokes added together.
    private func glowStroke(
        _ context: inout GraphicsContext, _ path: Path, color: Color, width: CGFloat, intensity: Double,
        dash: [CGFloat] = []
    ) {
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            let round = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dash)
            layer.stroke(path, with: .color(color.opacity(0.07 * intensity)), style: StrokeStyle(
                lineWidth: width * 5.5, lineCap: .round, lineJoin: .round, dash: dash))
            layer.stroke(path, with: .color(color.opacity(0.16 * intensity)), style: StrokeStyle(
                lineWidth: width * 2.6, lineCap: .round, lineJoin: .round, dash: dash))
            layer.stroke(path, with: .color(color.opacity(min(1, 0.95 * intensity))), style: round)
        }
    }

    private func drawBackground(_ context: inout GraphicsContext) {
        let shift = CGSize(width: parallax.width * 0.4, height: parallax.height * 0.4)
        let blobs: [(Color, Double, Double, Double, Double)] = [
            (Color(red: 0.20, green: 0.45, blue: 1.00), 0.72, 0.30, 0.55, 0.26),
            (Color(red: 0.10, green: 0.80, blue: 0.70), 0.60, 0.90, 0.50, 0.17),
            (Color(red: 0.50, green: 0.30, blue: 0.95), 0.90, 0.80, 0.48, 0.19),
        ]
        for (offset, blob) in blobs.enumerated() {
            let drift = time * (0.12 + Double(offset) * 0.05)
            let center = CGPoint(
                x: width * (blob.1 + 0.07 * sin(drift + Double(offset))) + shift.width,
                y: height * (blob.2 + 0.07 * cos(drift * 0.8 + Double(offset) * 2)) + shift.height)
            let radius = max(width, height) * blob.3
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(colors: [blob.0.opacity(blob.4), blob.0.opacity(0)]),
                    center: center, startRadius: 0, endRadius: radius))
        }
        var random = SplitMix(seed: 9)
        for _ in 0..<(compact ? 24 : 70) {
            let x = random.unit() * width, y = random.unit() * height
            let phase = random.unit() * 6.28, size = random.range(0.7, 1.8)
            let twinkle = 0.35 + 0.35 * sin(time * (0.8 + random.unit()) + phase)
            context.fill(
                Path(ellipseIn: CGRect(x: x + shift.width, y: y + shift.height, width: size, height: size)),
                with: .color(.white.opacity(twinkle * 0.6)))
        }
    }

    private func drawTrunk(_ context: inout GraphicsContext) {
        let grow = SceneTimeline.ease((time - 0.1) / 1.6)
        guard grow > 0.001 else { return }
        let points = (0...40).map { trunkPoint(Double($0) / 40 * grow) }
        glowStroke(&context, path(points), color: trunkColor, width: 3.5, intensity: 0.9 * gain)
    }

    private func drawTrunkNodes(_ context: inout GraphicsContext) {
        let grow = SceneTimeline.ease((time - 0.1) / 1.6)
        for step in 0..<14 {
            let s = Double(step) / 13
            guard s <= grow else { continue }
            drawNode(&context, at: trunkPoint(s), radius: 3.2, color: trunkColor, intensity: 0.9 * gain)
        }
    }

    private func drawNode(
        _ context: inout GraphicsContext, at center: CGPoint, radius: CGFloat, color: Color, intensity: Double
    ) {
        var boost = 1.0
        if let pointer {
            let screen = CGPoint(
                x: (pointer.x / 2 + 0.5) * width - parallax.width, y: (pointer.y / 2 + 0.5) * height - parallax.height)
            let distance = hypot(center.x - screen.x, center.y - screen.y)
            boost += max(0, 1 - distance / 120) * 1.4
        }
        let r = radius * CGFloat(min(boost, 2.2))
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.fill(
                Path(ellipseIn: CGRect(x: center.x - r * 3, y: center.y - r * 3, width: r * 6, height: r * 6)),
                with: .color(color.opacity(0.12 * intensity * boost)))
            layer.fill(
                Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                with: .color(color.opacity(min(1, intensity))))
        }
    }

    private func drawBranch(_ context: inout GraphicsContext, index: Int, branch: SceneGraph.Branch, points: [CGPoint]) {
        let grow = SceneTimeline.ease((time - SceneTimeline.growthStart - Double(index) * 0.17) / 1.1)
        guard grow > 0.001 else { return }
        let isStale = branch.kind == .stale
        let tint = color(for: branch.kind)
        let cut = SceneTimeline.cutOrder.firstIndex(of: index).map { SceneTimeline.cutTimes[$0] }

        if let cut, time >= cut {
            // The severed branch drifts off and wears away from the cut outward.
            let age = time - cut
            guard age < 1.2 else { return }
            let erosion = SceneTimeline.ease(age / 0.95)
            let drift = CGAffineTransform(translationX: CGFloat(branch.side) * CGFloat(age) * 20, y: -CGFloat(age) * 28)
            let remnant = path(points, from: erosion * 0.98, to: 1).applying(drift)
            glowStroke(
                &context, remnant, color: staleColor, width: 2.6, intensity: 0.7 * (1 - SceneTimeline.ease(age / 1.2)),
                dash: [4, 6])
            return
        }

        // Stale branches flicker like something no longer alive.
        let flicker = isStale ? 0.55 + 0.25 * sin(time * 7 + Double(index) * 2.1) : 1
        let intensity = (isStale ? 0.75 : 0.95) * flicker * (isStale ? 1 : gain)
        glowStroke(
            &context, path(points, from: 0, to: grow), color: tint, width: isStale ? 2.4 : 2.8,
            intensity: intensity, dash: isStale ? [5, 7] : [])
        guard grow > 0.97 else { return }
        for node in [0.4, 0.7, 1.0] {
            drawNode(
                &context, at: point(on: points, at: node), radius: node == 1.0 ? 4.2 : 2.4, color: tint,
                intensity: intensity)
        }
    }

    /// Bright dots travelling up the healthy branches: the work that is still flowing.
    private func drawPulses(_ context: inout GraphicsContext, index: Int, branch: SceneGraph.Branch, points: [CGPoint]) {
        let grow = SceneTimeline.ease((time - SceneTimeline.growthStart - Double(index) * 0.17) / 1.1)
        guard grow > 0.97 else { return }
        let tint = color(for: branch.kind)
        for pulse in 0..<2 {
            let u = (time * (0.16 + Double(index % 4) * 0.03) + Double(pulse) * 0.5 + Double(index) * 0.137)
                .truncatingRemainder(dividingBy: 1)
            let center = point(on: points, at: u)
            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                layer.fill(
                    Path(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)),
                    with: .color(tint.opacity(0.28 * gain)))
                layer.fill(
                    Path(ellipseIn: CGRect(x: center.x - 2.8, y: center.y - 2.8, width: 5.6, height: 5.6)),
                    with: .color(.white.opacity(0.95)))
            }
        }
    }

    // MARK: Labels

    private func drawLabels(_ context: inout GraphicsContext, curves: [[CGPoint]]) {
        for (index, branch) in graph.branches.enumerated() {
            guard let label = branch.label else { continue }
            let appear = SceneTimeline.ease((time - 2.2 - Double(index) * 0.1) / 0.6)
            guard appear > 0.01 else { continue }
            let tip = curves[index].last ?? .zero
            var text = label
            var tint = color(for: branch.kind)
            var alpha = appear * (branch.kind == .stale ? 0.95 : 0.7)

            if let cut = cutTime(of: index) {
                let age = time - cut
                guard age < 2.2 else { continue }
                text = "removed · undo for 30 days"
                tint = keptColor
                alpha = appear * (1 - SceneTimeline.ease((age - 1.3) / 0.9)) * SceneTimeline.ease(age / 0.2)
            }
            drawLabel(&context, text: text, near: tip, side: branch.side, tint: tint, alpha: alpha)
        }
    }

    private func drawLabel(
        _ context: inout GraphicsContext, text: String, near tip: CGPoint, side: Double, tint: Color, alpha: Double
    ) {
        let resolved = context.resolve(
            Text(text).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundColor(.white))
        let measured = resolved.measure(in: CGSize(width: 400, height: 40))
        let pad = CGSize(width: 9, height: 4)
        let anchorX = tip.x + CGFloat(side) * 12
        let chipWidth = measured.width + pad.width * 2
        let preferred = side > 0 ? anchorX : anchorX - chipWidth
        // A label never runs off the edge of the picture; near the edge it slides in and sits a little higher.
        let originX = min(max(preferred, width * 0.36), width - chipWidth - 22)
        let lift: CGFloat = originX == preferred ? 8 : 20
        let chip = CGRect(
            x: originX, y: tip.y - measured.height / 2 - pad.height - lift,
            width: chipWidth, height: measured.height + pad.height * 2)
        context.drawLayer { layer in
            layer.opacity = alpha
            layer.fill(Path(roundedRect: chip, cornerRadius: chip.height / 2), with: .color(ink.opacity(0.78)))
            layer.stroke(Path(roundedRect: chip, cornerRadius: chip.height / 2), with: .color(tint.opacity(0.7)), lineWidth: 1)
            layer.draw(resolved, at: CGPoint(x: chip.midX, y: chip.midY), anchor: .center)
        }
    }

    // MARK: The cut

    private func drawCut(_ context: inout GraphicsContext, position: Int, branchIndex: Int, points: [CGPoint]) {
        let cut = SceneTimeline.cutTimes[position]
        let age = time - cut
        guard age >= 0, age < 2.4 else { return }
        let branch = graph.branches[branchIndex]
        let base = points.first ?? .zero

        // Flash, shock ring and a streak across the branch.
        if age < 0.7 {
            let phase = age / 0.7
            let radius = 8 + 64 * SceneTimeline.ease(phase)
            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                layer.stroke(
                    Path(ellipseIn: CGRect(x: base.x - radius, y: base.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(ember.opacity(0.9 * (1 - phase))), lineWidth: 2.5 * (1 - phase) + 0.5)
                let core = 22 * (1 - SceneTimeline.ease(age / 0.22))
                layer.fill(
                    Path(ellipseIn: CGRect(x: base.x - core, y: base.y - core, width: core * 2, height: core * 2)),
                    with: .color(.white.opacity(0.95 * (1 - phase))))
                for spark in 0..<12 {
                    let angle = Double(spark) / 12 * 2 * .pi + Double(position)
                    let inner = radius * 0.45, outer = radius * 0.95
                    var line = Path()
                    line.move(to: CGPoint(x: base.x + CGFloat(cos(angle)) * inner, y: base.y + CGFloat(sin(angle)) * inner))
                    line.addLine(to: CGPoint(x: base.x + CGFloat(cos(angle)) * outer, y: base.y + CGFloat(sin(angle)) * outer))
                    layer.stroke(line, with: .color(ember.opacity(0.9 * (1 - phase))), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
            }
        }

        // Embers rising from the severed branch, rippling outward from the cut.
        for particle in 0..<48 {
            var random = SplitMix(seed: UInt64(position * 1000 + particle + 1))
            let along = random.unit()
            let start = point(on: points, at: along)
            let velocity = CGPoint(
                x: CGFloat(branch.side) * CGFloat(random.range(4, 36)) + CGFloat(random.range(-18, 18)),
                y: -CGFloat(random.range(18, 78)))
            let life = random.range(1.0, 2.1)
            let phase = random.unit() * 6.28
            let particleAge = age - along * 0.55
            guard particleAge > 0, particleAge < life else { continue }
            let fade = pow(1 - particleAge / life, 1.4)
            let center = CGPoint(
                x: start.x + velocity.x * CGFloat(particleAge) + CGFloat(sin(particleAge * 4 + phase)) * 6,
                y: start.y + velocity.y * CGFloat(particleAge))
            let radius = CGFloat(random.range(1.1, 2.9))
            let tint = particleAge < 0.35 ? ember : staleColor
            context.drawLayer { layer in
                layer.blendMode = .plusLighter
                layer.fill(
                    Path(ellipseIn: CGRect(x: center.x - radius * 3, y: center.y - radius * 3, width: radius * 6, height: radius * 6)),
                    with: .color(tint.opacity(0.16 * fade)))
                layer.fill(
                    Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(tint.opacity(0.95 * fade)))
            }
        }
    }

    /// A band of light climbing the trunk once the last stale branch is gone.
    private func drawBloom(_ context: inout GraphicsContext) {
        let last = SceneTimeline.cutTimes.last ?? 0
        let progress = (time - last - 0.3) / 2.2
        guard progress > 0, progress < 1 else { return }
        let center = trunkPoint(SceneTimeline.ease(progress))
        let radius: CGFloat = 140
        context.drawLayer { layer in
            layer.blendMode = .plusLighter
            layer.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(colors: [keptColor.opacity(0.32 * (1 - progress * 0.6)), keptColor.opacity(0)]),
                    center: center, startRadius: 0, endRadius: radius))
        }
    }

    // MARK: Scissors

    private func drawScissors(_ context: inout GraphicsContext, curves: [[CGPoint]]) {
        let bases = SceneTimeline.cutOrder.map { curves[$0].first ?? .zero }
        let aims = SceneTimeline.cutOrder.map { index -> Double in
            let points = curves[index]
            guard points.count > 4 else { return 0 }
            return atan2(Double(points[4].y - points[0].y), Double(points[4].x - points[0].x))
        }
        guard let state = scissorsState(bases: bases, aims: aims) else { return }
        let scale: CGFloat = compact ? 0.8 : 1.25
        var local = context
        local.translateBy(x: state.position.x, y: state.position.y)
        local.rotate(by: .radians(state.heading))
        local.scaleBy(x: scale, y: scale)

        // Two rigid halves turning about the pivot: the blade goes one way, its handle the other.
        for side in [-1.0, 1.0] {
            var half = local
            half.rotate(by: .radians(side * state.opening))
            let blade = Path { path in
                path.move(to: CGPoint(x: -4, y: 0))
                path.addLine(to: CGPoint(x: 6, y: CGFloat(side) * 5.5))
                path.addQuadCurve(to: CGPoint(x: 70, y: 0.6 * CGFloat(side)), control: CGPoint(x: 40, y: CGFloat(side) * 4.5))
                path.addLine(to: CGPoint(x: 6, y: -CGFloat(side) * 0.6))
                path.closeSubpath()
            }
            let arm = Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: -17, y: -CGFloat(side) * 10))
            }
            let ring = Path(ellipseIn: CGRect(x: -34, y: -CGFloat(side) * 10 - (side > 0 ? 17 : -1) , width: 21, height: 16))
            half.drawLayer { glow in
                glow.blendMode = .plusLighter
                glow.stroke(blade, with: .color(.white.opacity(0.30)), lineWidth: 8)
                glow.stroke(ring, with: .color(.white.opacity(0.22)), lineWidth: 7)
            }
            half.fill(blade, with: .linearGradient(
                Gradient(colors: [Color(white: 1.0), Color(white: 0.66)]),
                startPoint: CGPoint(x: 0, y: -4), endPoint: CGPoint(x: 70, y: 4)))
            half.stroke(arm, with: .color(Color(white: 0.9)), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
            half.stroke(ring, with: .color(Color(white: 0.94)), lineWidth: 3.4)
        }
        local.fill(Path(ellipseIn: CGRect(x: -3.5, y: -3.5, width: 7, height: 7)), with: .color(ember))
    }

    private struct ScissorsState {
        let position: CGPoint
        let heading: Double
        let opening: Double
    }

    private func lerpAngle(_ from: Double, _ to: Double, _ amount: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi }
        if delta < -.pi { delta += 2 * .pi }
        return from + delta * amount
    }

    /// One pair of scissors visiting every stale branch in turn: in from the corner, a snip at each base with the
    /// blades along the branch, out again. The turning is smoothed so they never jump to a new angle.
    private func scissorsState(bases: [CGPoint], aims: [Double]) -> ScissorsState? {
        guard !bases.isEmpty else { return nil }
        let entry = CGPoint(x: width + 70, y: -50)
        let exit = CGPoint(x: width + 90, y: height * 0.15)
        let arrivals = (0..<bases.count).map { SceneTimeline.firstScissorsArrival + Double($0) * SceneTimeline.gap }
        let dwell = SceneTimeline.dwell
        let end = (arrivals.last ?? 0) + dwell

        func travel(
            from a: CGPoint, to b: CGPoint, progress: Double, startAim: Double?, endAim: Double?
        ) -> (CGPoint, Double) {
            let eased = SceneTimeline.ease(progress)
            let lift = CGFloat(sin(.pi * eased)) * 46
            let course = atan2(Double(b.y - a.y), Double(b.x - a.x))
            let normal = CGPoint(x: -sin(course), y: cos(course))
            var heading = course
            if let startAim { heading = lerpAngle(startAim, heading, SceneTimeline.ease(progress / 0.3)) }
            if let endAim { heading = lerpAngle(heading, endAim, SceneTimeline.ease((progress - 0.7) / 0.3)) }
            return (
                CGPoint(
                    x: a.x + (b.x - a.x) * CGFloat(eased) + normal.x * lift,
                    y: a.y + (b.y - a.y) * CGFloat(eased) + normal.y * lift), heading)
        }

        if time < arrivals[0] - 1.0 || time > end + 1.0 { return nil }
        if time < arrivals[0] {
            let (position, heading) = travel(
                from: entry, to: bases[0], progress: (time - (arrivals[0] - 1.0)) / 1.0, startAim: nil, endAim: aims[0])
            return ScissorsState(position: position, heading: heading, opening: 0.42)
        }
        if time >= end {
            let last = bases.count - 1
            let (position, heading) = travel(
                from: bases[last], to: exit, progress: (time - end) / 1.0, startAim: aims[last], endAim: nil)
            return ScissorsState(position: position, heading: heading, opening: 0.3)
        }
        for index in bases.indices {
            let arrive = arrivals[index]
            if time < arrive + dwell {
                let phase = (time - arrive) / dwell
                return ScissorsState(
                    position: bases[index], heading: aims[index], opening: 0.5 * abs(sin(phase * .pi * 2)))
            }
            if index + 1 < bases.count, time < arrivals[index + 1] {
                let progress = (time - (arrive + dwell)) / (arrivals[index + 1] - arrive - dwell)
                let (position, heading) = travel(
                    from: bases[index], to: bases[index + 1], progress: progress,
                    startAim: aims[index], endAim: aims[index + 1])
                return ScissorsState(position: position, heading: heading, opening: 0.34)
            }
        }
        return nil
    }
}
