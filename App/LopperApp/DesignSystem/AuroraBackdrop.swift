import SwiftUI

/// A slow wash of colour on the dark stage: three soft lights drifting, and a few stars. No picture, so it can sit
/// behind anything without repeating the welcome screen's graph.
struct AuroraBackdrop: View {
    var intensity: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion || activeState == .inactive)) { timeline in
            Canvas { context, size in
                draw(&context, size: size, time: reduceMotion ? 6 : timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        let lights: [(Color, Double, Double, Double, Double)] = [
            (Color(red: 0.30, green: 0.85, blue: 0.62), 0.80, 0.22, 0.52, 0.17),
            (Color(red: 0.10, green: 0.62, blue: 0.58), 0.58, 0.98, 0.50, 0.15),
            (Color(red: 0.16, green: 0.50, blue: 0.34), 0.96, 0.78, 0.46, 0.14),
        ]
        for (offset, light) in lights.enumerated() {
            let drift = time * (0.07 + Double(offset) * 0.03)
            let center = CGPoint(
                x: size.width * (light.1 + 0.06 * sin(drift + Double(offset))),
                y: size.height * (light.2 + 0.06 * cos(drift * 0.8 + Double(offset) * 2)))
            let radius = max(size.width, size.height) * light.3
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                with: .radialGradient(
                    Gradient(colors: [light.0.opacity(light.4 * intensity), light.0.opacity(0)]),
                    center: center, startRadius: 0, endRadius: radius))
        }
        var random = SplitMix(seed: 9)
        for _ in 0..<46 {
            let x = random.unit() * size.width, y = random.unit() * size.height
            let phase = random.unit() * 6.28, dot = random.range(0.7, 1.7)
            let twinkle = 0.3 + 0.3 * sin(time * (0.5 + random.unit()) + phase)
            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: dot, height: dot)),
                with: .color(.white.opacity(twinkle * 0.55 * intensity)))
        }
    }
}
