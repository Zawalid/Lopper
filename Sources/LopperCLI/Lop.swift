import ArgumentParser

@available(macOS 14, *)
public struct Lop: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "lop",
        abstract: "Find and safely remove the branches, worktrees and generated folders you no longer need.",
        version: LopVersion.current,
        subcommands: [
            ScanCommand.self, ListCommand.self, WhyCommand.self, CleanCommand.self, HistoryCommand.self,
            UndoCommand.self, AgentsCommand.self, DiskCommand.self, FoldersCommand.self, DoctorCommand.self,
            RiskCommand.self,
            DiagnosticsCommand.self,
        ])

    public init() {}
}

public enum LopVersion {
    public static let current = "0.4.0"
}
