import Foundation

/// A small deterministic random source, so the picture is identical on every launch and every loop.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number in 0..<1.
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    mutating func range(_ low: Double, _ high: Double) -> Double { low + (high - low) * unit() }
}

/// The branches of the welcome picture. The big ones are placed by hand for a good composition, the small
/// ones grow out of them from a fixed seed.
struct SceneGraph {
    enum Kind: Equatable { case kept, active, stale }

    struct Branch {
        let kind: Kind
        /// Where it leaves its parent, 0...1 from the start of the parent (bottom of the trunk).
        let attach: Double
        /// Index of the branch it grows from, nil for the trunk.
        let parent: Int?
        let side: Double
        /// Horizontal reach as a fraction of the picture's width, and vertical rise as a fraction of its height.
        let reach: Double
        let rise: Double
        let label: String?
        let freedGB: Double
    }

    var branches: [Branch]

    static func make() -> SceneGraph {
        func trunk(
            _ attach: Double, _ side: Double, _ reach: Double, _ rise: Double, _ kind: Kind,
            _ label: String? = nil, gb: Double = 0
        ) -> Branch {
            Branch(kind: kind, attach: attach, parent: nil, side: side, reach: reach, rise: rise, label: label, freedGB: gb)
        }
        var branches: [Branch] = [
            trunk(0.10, -1, 0.20, 0.10, .active, "feat/search · 2h ago"),
            trunk(0.18, 1, 0.20, 0.12, .stale, "feat/old-login · 94 days idle", gb: 0.9),
            trunk(0.27, -1, 0.17, 0.11, .stale, "spike/auth-3 · merged", gb: 1.4),
            trunk(0.36, 1, 0.24, 0.14, .active, "feat/payments · in progress"),
            trunk(0.45, -1, 0.21, 0.12, .kept),
            trunk(0.52, 1, 0.17, 0.10, .stale, "fix/typo · merged", gb: 0.6),
            trunk(0.60, -1, 0.22, 0.13, .stale, "worktree/agent-7 · finished", gb: 1.1),
            trunk(0.69, 1, 0.22, 0.13, .kept),
            trunk(0.77, -1, 0.17, 0.10, .stale, "build/ · 0.5 GB of output", gb: 0.5),
            trunk(0.85, 1, 0.20, 0.10, .active, "release/2.4 · protected"),
            trunk(0.92, -1, 0.14, 0.08, .stale, "wip/dead-end · abandoned", gb: 0.8),
        ]
        // Small branches grow out of the healthy ones.
        var random = SplitMix(seed: 42)
        for (index, branch) in branches.enumerated() where branch.kind != .stale && branch.attach < 0.9 {
            branches.append(Branch(
                kind: .kept, attach: random.range(0.45, 0.7), parent: index,
                side: random.unit() < 0.5 ? -1 : 1, reach: random.range(0.06, 0.10), rise: random.range(0.05, 0.09),
                label: nil, freedGB: 0))
        }
        return SceneGraph(branches: branches)
    }
}

/// When things happen in the loop. All times are seconds from the start of the loop.
enum SceneTimeline {
    static let period: Double = 15
    static let growthStart: Double = 0.3
    static let firstScissorsArrival: Double = 4.2
    /// Time between one cut and the next: travel plus a short snip.
    static let gap: Double = 1.25
    static let cutDelay: Double = 0.17
    static let dwell: Double = 0.35
    /// The finished picture, used when motion is reduced.
    static let stillFrame: Double = 13

    private static let order: [Int] = SceneGraph.make().branches.enumerated()
        .filter { $0.element.kind == .stale }.map(\.offset)

    static var cutCount: Int { order.count }
    /// Indices of the stale branches, in the order they are cut.
    static var cutOrder: [Int] { order }

    static var cutTimes: [Double] {
        (0..<order.count).map { firstScissorsArrival + Double($0) * gap + cutDelay }
    }

    static var totalGB: Double {
        let graph = SceneGraph.make()
        return order.reduce(0) { $0 + graph.branches[$1].freedGB }
    }

    static func ease(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// Space freed so far. Each cut adds its branch's share over half a second.
    static func freedGB(at time: Double) -> Double {
        let graph = SceneGraph.make()
        var total = 0.0
        for (position, index) in order.enumerated() {
            total += graph.branches[index].freedGB * ease((time - cutTimes[position]) / 0.5)
        }
        return total
    }
}
