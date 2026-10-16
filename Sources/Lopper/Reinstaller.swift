import Foundation

/// Runs the install command that brings a cleared folder back, for the few commands Lopper recognises. Always
/// the lockfile-respecting form, so it can never pull different versions than the ones that were there.
public struct Reinstaller: Sendable {
    public enum Outcome: Sendable, Equatable {
        case done
        case unsupported
        case failed(String)
    }

    private static let commands: [String: String] = [
        "npm ci": "npm ci",
        "pnpm install": "pnpm install --frozen-lockfile",
        "yarn install": "yarn install --frozen-lockfile",
        "bun install": "bun install --frozen-lockfile",
    ]

    private let shell: URL
    private let shellArguments: [String]
    private let environment: [String: String]
    private let timeout: Duration

    /// A login shell by default, so the person's node version manager puts `npm` on the path as it would in
    /// their own terminal.
    public init(
        shell: URL = URL(fileURLWithPath: "/bin/zsh"), shellArguments: [String] = ["-l", "-c"],
        environment: [String: String] = [:], timeout: Duration = .seconds(900)
    ) {
        self.shell = shell
        self.shellArguments = shellArguments
        self.environment = environment
        self.timeout = timeout
    }

    public static func isSupported(_ how: String) -> Bool {
        commands[how] != nil
    }

    public func reinstall(in directory: URL, how: String) async -> Outcome {
        guard let command = Self.commands[how] else { return .unsupported }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return .failed("The project folder no longer exists") }

        // The folder must really be gone. `npm ci` removes node_modules itself, with no Trash and no undo record, so it
        // is only ever run to bring back a folder Lopper has just moved away.
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("node_modules").path) {
            return .failed("node_modules is still there, so nothing was reinstalled")
        }
        let runner = CommandRunner(executable: shell, timeout: timeout, environment: environment)
        do {
            let output = try await runner.run(shellArguments + [command], in: directory)
            if output.succeeded { return .done }
            let tail = output.stderr.split(separator: "\n").suffix(4).joined(separator: "\n")
            return .failed(tail.isEmpty ? "\(how) exited with status \(output.exitCode)" : tail)
        } catch CommandError.timedOut {
            return .failed("\(how) took too long and was stopped")
        } catch {
            return .failed(UserMessage.describe(error))
        }
    }
}
