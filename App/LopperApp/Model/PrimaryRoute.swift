import Foundation

/// The top-level pages in the sidebar, in order. One list feeds the sidebar rows and the menu shortcuts, so
/// they cannot drift apart.
enum PrimaryRoute: CaseIterable, Identifiable {
    case overview
    case agents
    case disk
    case history

    var id: Self { self }

    var route: Route {
        switch self {
        case .overview: .overview
        case .agents: .agents
        case .disk: .disk
        case .history: .history
        }
    }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .agents: "Agents"
        case .disk: "Disk"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .agents: "sparkles"
        case .disk: "internaldrive"
        case .history: "clock.arrow.circlepath"
        }
    }

    /// Command-1 through Command-4 in sidebar order.
    var shortcutDigit: Character {
        switch self {
        case .overview: "1"
        case .agents: "2"
        case .disk: "3"
        case .history: "4"
        }
    }
}
