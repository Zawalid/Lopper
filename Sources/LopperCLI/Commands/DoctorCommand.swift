import ArgumentParser
import Foundation
import Lopper

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor", abstract: "Check that git, the GitHub CLI, your folders and Lopper's files are in order.")

    @OptionGroup var options: GlobalOptions

    struct Check: Encodable {
        let name: String
        let ok: Bool
        let detail: String
    }

    func run() async throws {
        let session = try Session.open(options, requireFolders: false)
        var checks: [Check] = []

        let git = await Self.gitVersion()
        checks.append(Check(name: "git", ok: git != nil, detail: git ?? "not found. Install the command line tools: xcode-select --install"))

        let gh = GhCliProvider.locate()
        checks.append(Check(name: "GitHub CLI", ok: gh != nil,
                            detail: gh?.path ?? "not found (optional). Without it, merged pull requests are not detected."))

        let loaded = SettingsLoader.load(from: session.context.settingsURL)
        checks.append(Check(name: "settings", ok: true, detail: "\(session.context.settingsURL.path) (\(Self.describe(loaded.outcome)))"))

        let folders = loaded.settings.folders
        if folders.isEmpty {
            checks.append(Check(name: "folders", ok: false, detail: "none configured. Add one: lop folders add ~/Code"))
        }
        for folder in folders {
            let access = FolderProbe.check(folder.path)
            checks.append(Check(name: "folder", ok: access.isReadable, detail: Self.describe(access, folder.path.path)))
        }

        let history = await session.workspace.history()
        checks.append(Check(name: "undo log", ok: true, detail: "\(session.context.undoLogURL.path) (\(Format.count(history.count, "entry", "entries")))"))

        if options.json {
            session.console.line(try JSONOutput.string(["checks": checks], now: session.now))
        } else {
            for check in checks {
                let mark = check.ok ? session.style.green("ok  ") : session.style.red("fail")
                session.console.line("\(mark) \(Format.column(check.name, 11)) \(check.detail)")
            }
        }
        if checks.contains(where: { !$0.ok && $0.name != "GitHub CLI" }) { throw ExitCode(1) }
    }

    static func describe(_ access: FolderAccess, _ path: String) -> String {
        switch access {
        case .ok: path
        case .denied: "\(path) cannot be opened. Allow your terminal in System Settings, Privacy & Security, Files & Folders."
        case .missing: "\(path) was not found. Reconnect the drive, or remove it: lop folders remove \(path)"
        case .notAFolder: "\(path) is a file, not a folder."
        }
    }

    private static func describe(_ outcome: SettingsLoadOutcome) -> String {
        switch outcome {
        case .created: "no file yet, defaults in use"
        case .loaded: "loaded"
        case .migrated: "upgraded from an older version"
        case .recoveredFromCorruption: "could not be read, a backup was kept"
        case .newerVersion: "written by a newer Lopper"
        }
    }

    static func gitVersion() async -> String? {
        // /usr/bin/git is a stub without the command line tools, and running it opens Apple's installer.
        guard GitAvailability.isInstalled() else { return nil }
        let runner = GitRunner()
        guard let output = try? await runner.run(["--version"], in: FileManager.default.temporaryDirectory),
              output.succeeded else { return nil }
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
