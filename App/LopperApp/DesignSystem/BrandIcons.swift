import SwiftUI
import AppKit
import Lopper

/// Real icons for the tools Lopper talks about. Apps that are installed supply their own icon, read from the
/// system at runtime, so VS Code, Claude or Terminal look exactly as they do in the Dock. Nothing here ships
/// another company's artwork except the GitHub mark, which is the one thing with no app to read it from.
enum BrandIcons {
    /// Candidate bundle identifiers per tool, most specific first.
    static func bundleIDs(for tool: AgentTool) -> [String] {
        switch tool {
        case .claudeCode: ["com.anthropic.claudefordesktop"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .codex: ["com.openai.codex", "com.openai.chat"]
        case .conductor: ["com.conductor.app"]
        }
    }

    static func fallbackSymbol(for tool: AgentTool) -> String {
        switch tool {
        case .claudeCode: "sparkle"
        case .cursor: "cursorarrow.rays"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .conductor: "music.note.list"
        }
    }

    static func firstInstalled(_ candidates: [String], isInstalled: (String) -> Bool) -> String? {
        candidates.first(where: isInstalled)
    }

    /// The GitHub mark as a template image, so it takes the surrounding text color. The path is GitHub's
    /// published Octicon `mark-github` (MIT licensed).
    @MainActor
    static let githubMark: NSImage? = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16"><path fill-rule="evenodd" d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/></svg>
        """
        let image = NSImage(data: Data(svg.utf8))
        image?.isTemplate = true
        return image
    }()
}

/// An installed app's own icon, or a symbol when it is not installed.
struct AppIconView: View {
    let bundleID: String?
    let fallbackSymbol: String
    var size: CGFloat = 16

    var body: some View {
        if let bundleID, let image = OpenActions.icon(forBundleID: bundleID) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: size * 0.8))
                .frame(width: size, height: size)
        }
    }
}

/// The icon of the AI tool that made a worktree.
struct AgentToolIcon: View {
    let tool: AgentTool
    var size: CGFloat = 14

    var body: some View {
        AppIconView(
            bundleID: BrandIcons.firstInstalled(BrandIcons.bundleIDs(for: tool), isInstalled: { OpenActions.installed($0) }),
            fallbackSymbol: BrandIcons.fallbackSymbol(for: tool),
            size: size)
    }
}

struct GitHubMarkView: View {
    var size: CGFloat = 14

    var body: some View {
        if let mark = BrandIcons.githubMark {
            Image(nsImage: mark)
                .resizable()
                .renderingMode(.template)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "arrow.up.right.square").frame(width: size, height: size)
        }
    }
}
