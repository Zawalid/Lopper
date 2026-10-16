import Foundation
import os

public struct CommandOutput: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public var succeeded: Bool { exitCode == 0 }

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum CommandError: Error, Equatable, Sendable {
    case launchFailed(String)
    case timedOut(command: String)
    case failed(command: String, exitCode: Int32, stderr: String)
}

/// Runs one external executable and captures its output.
/// Honors task cancellation and a hard timeout; never blocks the cooperative pool.
public struct CommandRunner: Sendable {
    public var executable: URL
    public var timeout: Duration
    public var environment: [String: String]
    /// Decides which variables of the calling process the command inherits. Everything by default.
    public var inheritsVariable: @Sendable (String) -> Bool

    public init(
        executable: URL,
        timeout: Duration = .seconds(30),
        environment: [String: String] = [:],
        inheritsVariable: @escaping @Sendable (String) -> Bool = { _ in true }
    ) {
        self.executable = executable
        self.timeout = timeout
        self.environment = environment
        self.inheritsVariable = inheritsVariable
    }

    public func run(_ arguments: [String], in directory: URL? = nil) async throws -> CommandOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment.filter { inheritsVariable($0.key) }
        for (key, value) in environment { env[key] = value }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let command = ([executable.lastPathComponent] + arguments).joined(separator: " ")
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let box = ProcessBox(process)
        let limit = timeout

        async let stdoutData = Self.drain(stdoutPipe.fileHandleForReading)
        async let stderrData = Self.drain(stderrPipe.fileHandleForReading)

        // The watchdog must end with the command. Left sleeping it keeps the process and its pipes alive for the whole
        // timeout, and a scan that runs thousands of git commands then runs out of file descriptors.
        let watchdog = Task {
            do { try await Task.sleep(for: limit) } catch { return }
            if box.process.isRunning {
                timedOut.withLock { $0 = true }
                box.process.terminate()
            }
        }
        defer { watchdog.cancel() }

        let status: Int32
        do {
            status = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                    box.process.terminationHandler = { finished in
                        continuation.resume(returning: finished.terminationStatus)
                    }
                    do {
                        try box.process.run()
                    } catch {
                        try? stdoutPipe.fileHandleForWriting.close()
                        try? stderrPipe.fileHandleForWriting.close()
                        continuation.resume(throwing: CommandError.launchFailed(String(describing: error)))
                    }
                }
            } onCancel: {
                if box.process.isRunning { box.process.terminate() }
            }
        } catch {
            _ = await stdoutData
            _ = await stderrData
            throw error
        }

        let out = await stdoutData
        let err = await stderrData
        // A cancelled caller terminated the process above; report cancellation, not a fake exit status.
        try Task.checkCancellation()
        if timedOut.withLock({ $0 }) {
            throw CommandError.timedOut(command: command)
        }
        return CommandOutput(
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self),
            exitCode: status
        )
    }

    private static func drain(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}
