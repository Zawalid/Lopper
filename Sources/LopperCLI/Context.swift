import ArgumentParser
import Foundation
import Lopper

/// Everything a command needs from the outside world. Tests replace it with a throwaway folder, a fake terminal
/// and a clock, through a task-local value, so no test ever touches real settings or a real undo log.
public struct CLIContext: Sendable {
    public var console: any Console
    public var settingsURL: URL
    public var undoLogURL: URL
    /// Whether to ask the GitHub CLI about merged pull requests. Off in tests.
    public var detectPullRequests: Bool
    /// Where cleared generated folders go. The system Trash, except in tests.
    public var trash: any TrashProvider
    public var now: @Sendable () -> Date

    public init(
        console: any Console, settingsURL: URL, undoLogURL: URL, detectPullRequests: Bool = true,
        trash: any TrashProvider = SystemTrash(), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.console = console
        self.settingsURL = settingsURL
        self.undoLogURL = undoLogURL
        self.detectPullRequests = detectPullRequests
        self.trash = trash
        self.now = now
    }

    public static func live(color: Bool = true) -> CLIContext {
        let support = LopperSupport.directory()
        return CLIContext(
            console: SystemConsole(color: color),
            settingsURL: support.appendingPathComponent("settings.json"),
            undoLogURL: UndoLog.defaultURL)
    }

    @TaskLocal public static var current: CLIContext = .live()
}

/// Options every command shares.
struct GlobalOptions: ParsableArguments {
    @Flag(name: .long, help: "Print machine-readable JSON instead of text.")
    var json = false

    @Flag(name: .customLong("no-color"), help: "Never use colors.")
    var noColor = false

    @Flag(name: .customLong("no-gh"), help: "Do not ask the GitHub CLI about merged pull requests.")
    var noGitHub = false

    @Option(name: .customLong("folder"), help: "Scan this folder instead of the configured ones. Repeatable.")
    var folders: [String] = []
}

/// A command's view of the world: the settings, the engine front door, and a console.
struct Session {
    let context: CLIContext
    let options: GlobalOptions
    let settings: Settings
    let workspace: Workspace
    let console: any Console
    let style: Style

    static func open(_ options: GlobalOptions, requireFolders: Bool = true) throws -> Session {
        let context = CLIContext.current
        let loaded = SettingsLoader.load(from: context.settingsURL)
        var settings = loaded.settings
        if !options.folders.isEmpty {
            settings.folders = options.folders.map {
                FolderSetting(path: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true))
            }
        }
        if requireFolders && settings.roots.isEmpty {
            throw ValidationError(
                "No folders to scan. Add one with `lop folders add ~/Code`, or pass --folder <path>.")
        }
        let usePRs = context.detectPullRequests && !options.noGitHub
        let workspace = Workspace(
            settings: settings, prProvider: usePRs ? GhCliProvider() : nil,
            undoLog: UndoLog(url: context.undoLogURL), trash: context.trash, now: context.now)
        let console = context.console
        let color = console.useColor && !options.noColor
        return Session(
            context: context, options: options, settings: settings, workspace: workspace, console: console,
            style: Style(enabled: color))
    }

    var now: Date { context.now() }
}
