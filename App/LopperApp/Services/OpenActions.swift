import AppKit

@MainActor
enum OpenActions {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func openInTerminal(_ folder: URL, bundleID: String = TerminalChoice.terminal.rawValue) {
        open(folder, withBundleID: bundleID)
    }

    static func openInEditor(_ folder: URL, bundleID: String) {
        open(folder, withBundleID: bundleID)
    }

    /// Opens a folder in any installed app, for the "Open with" menu.
    static func openWith(_ folder: URL, bundleID: String) {
        open(folder, withBundleID: bundleID)
    }

    /// The app's own icon at menu size, so the list looks like Finder's "Open With".
    static func icon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        return image
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

enum TerminalChoice: String, CaseIterable, Identifiable {
    case terminal = "com.apple.Terminal"
    case iterm = "com.googlecode.iterm2"
    case ghostty = "com.mitchellh.ghostty"
    case warp = "dev.warp.Warp-Stable"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm: "iTerm2"
        case .ghostty: "Ghostty"
        case .warp: "Warp"
        }
    }
}

