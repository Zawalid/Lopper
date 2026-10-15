import Foundation

/// The top-level pages in the sidebar, in order. One list feeds the sidebar rows and the menu shortcuts, so
/// they cannot drift apart.
enum PrimaryRoute: CaseIterable, Identifiable {
    case overview
    case agents
    case history

    var id: Self { self }

    var route: Route {
        switch self {
        case .overview: .overview
        case .agents: .agents
        case .history: .history
        }
    }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .agents: "Agents"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .agents: "sparkles"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// Command-1, Command-2, Command-3 in sidebar order.
    var shortcutDigit: Character {
        switch self {
        case .overview: "1"
        case .agents: "2"
        case .history: "3"
        }
    }
}
