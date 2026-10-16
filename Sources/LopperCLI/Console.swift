import Foundation

/// Where the command line talks to the person. A protocol so every command can be tested without a terminal.
public protocol Console: Sendable {
    /// True when both input and output are a terminal, so it is reasonable to ask a question.
    var isInteractive: Bool { get }
    var useColor: Bool { get }
    func write(_ text: String)
    func writeError(_ text: String)
    func readLine() -> String?
}

extension Console {
    func line(_ text: String = "") { write(text + "\n") }
    func errorLine(_ text: String) { writeError(text + "\n") }

    /// Asks a yes or no question. Anything but an explicit yes means no.
    func confirm(_ prompt: String) -> Bool {
        write("\(prompt) [y/N] ")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }
}

public struct SystemConsole: Console {
    public let useColor: Bool

    public init(color: Bool = true) {
        let noColor = ProcessInfo.processInfo.environment["NO_COLOR"] != nil
        useColor = color && !noColor && isatty(STDOUT_FILENO) == 1
    }

    public var isInteractive: Bool { isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 }

    public func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }

    public func writeError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    public func readLine() -> String? {
        Swift.readLine()
    }
}
