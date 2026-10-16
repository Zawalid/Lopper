import ArgumentParser
import Foundation
import Lopper

struct DiagnosticsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnostics",
        abstract: "Print a report you can read and paste into a bug report. Nothing is sent anywhere.",
        discussion: """
            The report has versions, setup problems, settings as counts, the last scan's timings and recent problems. \
            Repository and branch names are replaced by repo-1 and branch-1 unless you pass --include-names. Home \
            folders, credentials and email addresses are always removed.
            """)

    @OptionGroup var options: GlobalOptions

    @Flag(name: .customLong("include-names"), help: "Keep repository and branch names in the report.")
    var includeNames = false

    @Flag(name: .customLong("no-scan"), help: "Do not scan. Faster, but the report has no fresh timings and cannot hide names it did not see.")
    var noScan = false

    func run() async throws {
        let session = try Session.open(options, requireFolders: false)
        let log = DiagnosticLog(url: session.context.diagnosticLogURL)
        let folders = session.settings.folders
        let access = folders.filter(\.isEnabled).map { FolderProbe.check($0.path) }

        var repositoryNames: [String] = []
        var branchNames: [String] = []
        if !noScan, !session.settings.roots.isEmpty {
            let started = Date()
            let scan = await session.workspace.scan(measureSizes: false)
            let seconds = Date().timeIntervalSince(started)
            repositoryNames = scan.snapshots.map(\.repo.name)
            branchNames = scan.rows.map(\.title)
            await log.record(DiagnosticEvent(
                timestamp: session.now, kind: .scanFinished, message: "",
                numbers: ["repositories": Double(scan.snapshots.count), "failures": Double(scan.failures.count), "scanSeconds": seconds]))
            for failure in scan.failures {
                await log.record(DiagnosticEvent(timestamp: session.now, kind: .scanFailure, message: "\(failure.root.lastPathComponent): \(failure.message)"))
            }
        }

        let git = await SystemFacts.gitVersion()
        let input = DiagnosticsInput(
            appVersion: "lop \(LopVersion.current)", osVersion: SystemFacts.osVersion(), architecture: SystemFacts.architecture(),
            gitVersion: git, gitHubCLIVersion: await SystemFacts.gitHubCLIVersion(),
            setupProblems: SystemFacts.setupProblems(gitVersion: git, folderAccess: access),
            settings: session.settings, folderAccess: access, history: await session.workspace.history(),
            events: await log.events(now: session.now), repositoryNames: repositoryNames, branchNames: branchNames, now: session.now)
        let text = DiagnosticsReport.text(input, includeNames: includeNames)

        if options.json {
            session.console.line(try JSONOutput.string(["report": text, "namesIncluded": includeNames ? "true" : "false"], now: session.now))
        } else {
            session.console.write(text)
        }
    }
}
