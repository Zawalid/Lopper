import ArgumentParser
import Foundation
import Lopper

struct FoldersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "folders", abstract: "Choose the folders Lopper looks in. They are shared with the app.",
        subcommands: [List.self, Add.self, Remove.self], defaultSubcommand: List.self)

    /// The folder as git and the app see it: tilde expanded, symlinks resolved.
    static func canonical(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "Show the folders Lopper scans.")
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let session = try Session.open(options, requireFolders: false)
            if options.json {
                session.console.line(try JSONOutput.string(
                    ["folders": session.settings.folders.map { ["path": $0.path.path, "enabled": $0.isEnabled ? "true" : "false"] }],
                    now: session.now))
                return
            }
            if session.settings.folders.isEmpty {
                session.console.line("No folders yet. Add one with `lop folders add ~/Code`.")
                return
            }
            for folder in session.settings.folders {
                session.console.line("\(folder.isEnabled ? " " : "-") \(folder.path.path)")
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "add", abstract: "Add a folder to scan.")
        @OptionGroup var options: GlobalOptions

        @Argument(help: "The folder, for example ~/Code.")
        var path: String

        func run() async throws {
            let session = try Session.open(options, requireFolders: false)
            let url = FoldersCommand.canonical(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ValidationError("\(url.path) is not a folder.")
            }
            var settings = SettingsLoader.load(from: session.context.settingsURL).settings
            guard !settings.folders.contains(where: { $0.path.resolvingSymlinksInPath().path == url.path }) else {
                session.console.line("\(url.path) is already in the list.")
                return
            }
            settings.folders.append(FolderSetting(path: url))
            try FileManager.default.createDirectory(
                at: session.context.settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try settings.save(to: session.context.settingsURL)
            session.console.line("Added \(url.path).")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove", abstract: "Stop scanning a folder. Nothing in it is touched.")
        @OptionGroup var options: GlobalOptions

        @Argument(help: "The folder to remove from the list.")
        var path: String

        func run() async throws {
            let session = try Session.open(options, requireFolders: false)
            let url = FoldersCommand.canonical(path)
            var settings = SettingsLoader.load(from: session.context.settingsURL).settings
            let before = settings.folders.count
            settings.folders.removeAll { $0.path.resolvingSymlinksInPath().path == url.path }
            guard settings.folders.count < before else {
                throw ValidationError("\(url.path) is not in the list. `lop folders` shows it.")
            }
            try settings.save(to: session.context.settingsURL)
            session.console.line("Removed \(url.path) from the list. Its contents were not touched.")
        }
    }
}
