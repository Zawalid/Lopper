import Foundation

/// The panes of the Settings window. Adding a page means adding a case here and one file for its view; the
/// window, its tabs and the tests that visit every pane pick it up from this list.
enum SettingsPane: CaseIterable, Identifiable, Hashable {
    case general
    case folders
    case safety
    case rules
    case tools
    case notifications
    case advanced
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .folders: "Folders"
        case .safety: "Safety"
        case .rules: "Rules"
        case .tools: "Tools"
        case .notifications: "Notifications"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .folders: "folder"
        case .safety: "checkmark.shield"
        case .rules: "wand.and.stars"
        case .tools: "wrench.and.screwdriver"
        case .notifications: "bell"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }

    /// Panes whose feature does not exist yet stay hidden instead of showing an empty page.
    var isAvailable: Bool {
        switch self {
        case .notifications: false
        default: true
        }
    }

    static var available: [SettingsPane] {
        allCases.filter(\.isAvailable)
    }
}
