import ArgumentParser

public struct Lop: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "lop",
        abstract: "Find and safely remove the branches, worktrees and generated folders you no longer need.",
        version: LopVersion.current,
        subcommands: [
            ScanCommand.self, ListCommand.self, WhyCommand.self, CleanCommand.self, HistoryCommand.self,
            UndoCommand.self,
        ])

    public init() {}
}

public enum LopVersion {
    public static let current = "0.1.0"
}
