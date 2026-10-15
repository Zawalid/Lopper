import AppKit

@MainActor
enum OpenActions {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func openInTerminal(_ folder: URL) {
        open(folder, withBundleID: "com.apple.Terminal")
    }

    static func openInEditor(_ folder: URL, bundleID: String) {
        open(folder, withBundleID: bundleID)
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    static func installed(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    private static func open(_ folder: URL, withBundleID bundleID: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSWorkspace.shared.open(folder)
            return
        }
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

enum EditorChoice: String, CaseIterable, Identifiable {
    case vscode = "com.microsoft.VSCode"
    case cursor = "com.todesktop.230313mzl4w4u92"
    case xcode = "com.apple.dt.Xcode"
    case zed = "dev.zed.Zed"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .vscode: "Visual Studio Code"
        case .cursor: "Cursor"
        case .xcode: "Xcode"
        case .zed: "Zed"
        }
    }
}
