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
    /// The local diagnostics log. Beside the settings file unless a test or the live context says otherwise.
    public var diagnosticLogURL: URL

    public init(
        console: any Console, settingsURL: URL, undoLogURL: URL, detectPullRequests: Bool = true,
        trash: any TrashProvider = SystemTrash(), now: @escaping @Sendable () -> Date = { Date() },
        diagnosticLogURL: URL? = nil
    ) {
        self.diagnosticLogURL = diagnosticLogURL ?? settingsURL.deletingLastPathComponent().appendingPathComponent("diagnostics.log")
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
    /// How the settings file was read. A damaged or unreadable file means defaults are in use, which resets the
    /// person's protected branches, so anything that removes or saves must call `requireTrustedSettings()`.
    let settingsOutcome: SettingsLoadOutcome
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
        switch loaded.outcome {
        case .unreadable:
            console.writeError("warning: the settings file could not be read, so defaults are in use.\n")
        case .recoveredFromCorruption(let backup):
            console.writeError("warning: part of the settings file could not be read (original kept as \(backup.lastPathComponent)), so some settings are defaults.\n")
        default: break
        }
        return Session(
            context: context, options: options, settings: settings, settingsOutcome: loaded.outcome, workspace: workspace,
            console: console, style: Style(enabled: color))
    }

    /// Refuses to go on when the settings file was damaged or unreadable. Defaults would put the person's own protected
    /// branches, hidden repositories and throwaway names back to the built-in ones, and a save would then overwrite
    /// what they wrote.
    func requireTrustedSettings() throws {
        switch settingsOutcome {
        case .unreadable:
            throw ValidationError(
                "The settings file \(context.settingsURL.path) exists but cannot be read, so Lopper would use defaults "
                    + "instead of your protected branches. Fix its permissions and try again (`lop doctor` shows more).")
        case .recoveredFromCorruption(let backup):
            throw ValidationError(
                "Part of the settings file could not be read, so some of your settings would be defaults, including "
                    + "possibly your protected branches. The original is kept as \(backup.lastPathComponent). Fix "
                    + "\(context.settingsURL.lastPathComponent) (`lop doctor` shows more) and try again.")
        default:
            return
        }
    }

    var now: Date { context.now() }
}
