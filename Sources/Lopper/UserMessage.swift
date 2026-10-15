import Foundation

/// Turns engine errors into one plain sentence for a person. Raw command lines, exit codes and Swift
/// error dumps never reach the interface.
public enum UserMessage {
    public static func describe(_ error: Error) -> String {
        switch error {
        case let CommandError.failed(_, _, stderr):
            let detail = firstUsefulLine(of: stderr)
            return detail.isEmpty
                ? "git couldn't complete this step."
                : "git couldn't complete this step: \(detail)"
        case CommandError.timedOut:
            return "git took too long to respond. The repository may be very large or on a slow disk."
        case CommandError.launchFailed:
            return "Lopper couldn't start git. Install the Xcode command line tools and try again."
        case CleanError.movedAfterVerification:
            return "This item changed after you reviewed it, so it was left alone."
        case CleanError.checkedOut:
            return "A worktree started using this branch, so it was left alone."
        case let CleanError.restoreBlocked(reason):
            return "Can't restore this: \(reason)."
        case is CancellationError:
            return "Cancelled."
        default:
            return "Something unexpected went wrong."
        }
    }

    private static func firstUsefulLine(of text: String) -> String {
        let line = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        for prefix in ["fatal: ", "error: ", "warning: "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return line
    }
}
