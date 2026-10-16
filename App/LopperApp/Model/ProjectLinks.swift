import Foundation

/// Every address the app points people to, in one place so the About pane, the menus and the tests agree.
enum ProjectLinks {
    static let author = "Walid Zakan"
    static let authorHandle = "Zawalid"

    enum Link: CaseIterable {
        case authorGitHub, authorWebsite, authorX, repository, issues, newIssue, license

        var url: URL {
            let address: String
            switch self {
            case .authorGitHub: address = "https://github.com/Zawalid"
            case .authorWebsite: address = "https://zawalid.com"
            case .authorX: address = "https://x.com/Zawaalid"
            case .repository: address = "https://github.com/Zawalid/Lopper"
            case .issues: address = "https://github.com/Zawalid/Lopper/issues"
            case .newIssue: address = "https://github.com/Zawalid/Lopper/issues/new?template=bug_report.md"
            case .license: address = "https://github.com/Zawalid/Lopper/blob/main/LICENSE"
            }
            return URL(string: address) ?? URL(fileURLWithPath: "/")
        }
    }
}
