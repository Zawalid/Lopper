import Foundation

/// One thing worth knowing when something goes wrong, kept on this Mac only.
public struct DiagnosticEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case scanFinished, scanFailure, cleanProblem, restoreProblem, setupIssue
    }

    public let timestamp: Date
    public let kind: Kind
    /// Already scrubbed of home folders, credentials and email addresses when it is recorded.
    public let message: String
    /// Counts and durations, for example `repositories`, `failures`, `scanSeconds`.
    public let numbers: [String: Double]

    public init(timestamp: Date, kind: Kind, message: String, numbers: [String: Double] = [:]) {
        self.timestamp = timestamp
        self.kind = kind
        self.message = message
        self.numbers = numbers
    }
}

/// Removes what a person would not want to paste into a public bug report: where they keep their files, passwords
/// inside remote addresses, access tokens and email addresses.
public enum DiagnosticScrubber {
    public static func scrub(_ text: String, home: String = NSHomeDirectory()) -> String {
        var result = text
        if !home.isEmpty, home != "/" { result = result.replacingOccurrences(of: home, with: "~") }
        // Any other account's home folder: the name is the person.
        result = replace(#"/Users/[^/\s:]+"#, in: result, with: "~")
        result = replace(#"(?i)\b(https?|ssh|git)://[^/@\s]+@"#, in: result, with: "$1://")
        result = replace(
            #"\b(?:gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{16,})\b"#,
            in: result, with: "<token>")
        result = replace(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"#, in: result, with: "<email>")
        return result
    }

    /// Replaces repository and branch names with stable stand-ins (`repo-1`, `branch-2`), so a report can still be
    /// read ("branch-2 was skipped") without saying what the work is called.
    public static func pseudonymize(_ text: String, repositories: [String], branches: [String]) -> String {
        // These say nothing about the person's work and make the report easier to read.
        let common: Set<String> = ["main", "master", "develop", "HEAD", "origin"]
        var pairs: [(name: String, stand: String)] = []
        for (index, name) in Set(repositories).sorted().enumerated() where !name.isEmpty && !common.contains(name) {
            pairs.append((name, "repo-\(index + 1)"))
        }
        for (index, name) in Set(branches).sorted().enumerated() where !name.isEmpty && !common.contains(name) {
            pairs.append((name, "branch-\(index + 1)"))
        }
        var result = text
        // Longest first, so "feature/login-page" is replaced before "feature".
        for pair in pairs.sorted(by: { $0.name.count > $1.name.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: pair.name)
            result = replace("(?<![A-Za-z0-9_./-])\(escaped)(?![A-Za-z0-9_-])", in: result, with: pair.stand)
        }
        return result
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

/// A small local log shared by the app and `lop`. It is capped in size and age, never leaves the Mac, and a damaged
/// line is skipped instead of breaking the report.
public actor DiagnosticLog {
    public static let maxEvents = 500
    public static let maxAgeDays = 30

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var defaultURL: URL { LopperSupport.directory().appendingPathComponent("diagnostics.log") }

    public func record(_ event: DiagnosticEvent) {
        let scrubbed = DiagnosticEvent(
            timestamp: event.timestamp, kind: event.kind, message: DiagnosticScrubber.scrub(event.message),
            numbers: event.numbers)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(scrubbed) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
        compactIfNeeded(now: event.timestamp)
    }

    /// Oldest first. Expired and damaged lines are left out.
    public func events(now: Date = Date()) -> [DiagnosticEvent] {
        let cutoff = now.addingTimeInterval(-TimeInterval(Self.maxAgeDays) * 86_400)
        return readAll().filter { $0.timestamp >= cutoff }.suffix(Self.maxEvents).map { $0 }
    }

    private func readAll() -> [DiagnosticEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(DiagnosticEvent.self, from: Data($0)) }
    }

    /// Rewrites the file down to the cap now and then, so appending stays cheap and the file stays small.
    private func compactIfNeeded(now: Date) {
        guard let data = try? Data(contentsOf: url), data.count > 64_000 || data.split(separator: 0x0A).count > Self.maxEvents + 100
        else { return }
        let kept = events(now: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var output = Data()
        for event in kept {
            if let line = try? encoder.encode(event) { output.append(line); output.append(0x0A) }
        }
        try? output.write(to: url, options: .atomic)
    }
}

public struct DiagnosticsInput: Sendable {
    public var appVersion: String
    public var osVersion: String
    public var architecture: String
    public var gitVersion: String?
    public var gitHubCLIVersion: String?
    /// Plain sentences, for example "git is not installed".
    public var setupProblems: [String]
    public var settings: Settings
    public var folderAccess: [FolderAccess]
    public var history: [UndoRecord]
    public var events: [DiagnosticEvent]
    public var repositoryNames: [String]
    public var branchNames: [String]
    public var now: Date

    public init(
        appVersion: String, osVersion: String, architecture: String, gitVersion: String?, gitHubCLIVersion: String?,
        setupProblems: [String], settings: Settings, folderAccess: [FolderAccess], history: [UndoRecord],
        events: [DiagnosticEvent], repositoryNames: [String], branchNames: [String], now: Date
    ) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.architecture = architecture
        self.gitVersion = gitVersion
        self.gitHubCLIVersion = gitHubCLIVersion
        self.setupProblems = setupProblems
        self.settings = settings
        self.folderAccess = folderAccess
        self.history = history
        self.events = events
        self.repositoryNames = repositoryNames
        self.branchNames = branchNames
        self.now = now
    }
}

/// The text a person can read, copy and attach to a bug report. Built from counts and flags; names only when asked.
public enum DiagnosticsReport {
    public static let eventLimit = 50

    public static func text(_ input: DiagnosticsInput, includeNames: Bool) -> String {
        var lines: [String] = []
        func section(_ title: String, _ body: [String]) {
            lines.append("")
            lines.append(title)
            lines += body.map { "  " + $0 }
        }

        lines.append("Lopper diagnostics")
        lines.append("Generated \(iso(input.now))")
        lines.append(includeNames
            ? "Names: included"
            : "Names: left out (repositories show as repo-1, branches as branch-1)")

        section("App", [
            "Lopper: \(input.appVersion)",
            "macOS: \(input.osVersion) (\(input.architecture))",
            "git: \(input.gitVersion ?? "not found")",
            "GitHub CLI: \(input.gitHubCLIVersion ?? "not found")",
        ])
        section("Setup", input.setupProblems.isEmpty ? ["no problems"] : input.setupProblems)

        let settings = input.settings
        let enabled = settings.folders.filter(\.isEnabled).count
        var access: [String] = []
        for (label, kind) in [("readable", FolderAccess.ok), ("no access", .denied), ("not found", .missing), ("not a folder", .notAFolder)] {
            let count = input.folderAccess.filter { $0 == kind }.count
            if count > 0 { access.append("\(count) \(label)") }
        }
        section("Settings", [
            "folders: \(settings.folders.count) (\(enabled) enabled), \(access.isEmpty ? "access not checked" : access.joined(separator: ", "))",
            "scan depth \(settings.scanDepth), stale after \(settings.staleDays) days, undo kept \(settings.trashRetentionDays) days",
            "protected patterns: \(settings.protectedPatterns.count), repositories with their own settings: \(settings.repos.count)",
        ])

        let scans = input.events.filter { $0.kind == .scanFinished }
        if let last = scans.last {
            let n = last.numbers
            var parts = ["\(Int(n["repositories"] ?? 0)) repositories", "\(Int(n["failures"] ?? 0)) failed"]
            if let seconds = n["scanSeconds"] { parts.append("scan \(format(seconds))") }
            if let seconds = n["sizeSeconds"] { parts.append("sizes \(format(seconds))") }
            section("Last scan", ["\(iso(last.timestamp)): " + parts.joined(separator: ", ")])
        } else {
            section("Last scan", ["none recorded"])
        }

        var counts: [String: Int] = [:]
        for record in input.history { counts["\(record.action.rawValue) \(record.status.rawValue)", default: 0] += 1 }
        section("History", counts.isEmpty ? ["no removals"] : counts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })

        let shown = input.events.filter { $0.kind != .scanFinished }.suffix(eventLimit)
        let eventLines = shown.map { event -> String in
            let message = clean(event.message, input: input, includeNames: includeNames)
            return "\(iso(event.timestamp)) \(event.kind.rawValue): \(message)"
        }
        section("Recent events", eventLines.isEmpty ? ["none"] : eventLines)
        return lines.joined(separator: "\n") + "\n"
    }

    private static func clean(_ message: String, input: DiagnosticsInput, includeNames: Bool) -> String {
        let scrubbed = DiagnosticScrubber.scrub(message)
        return includeNames
            ? scrubbed
            : DiagnosticScrubber.pseudonymize(scrubbed, repositories: input.repositoryNames, branches: input.branchNames)
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func format(_ seconds: Double) -> String {
        seconds < 10 ? String(format: "%.1fs", seconds) : String(format: "%.0fs", seconds)
    }
}

/// Facts about this Mac and the tools Lopper uses, read the same way by the app and by `lop`.
public enum SystemFacts {
    public static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    public static func architecture() -> String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    /// Never runs git when the command line tools are missing, because `/usr/bin/git` would then open Apple's installer.
    public static func gitVersion(git: GitRunner = GitRunner()) async -> String? {
        guard GitAvailability.isInstalled(),
            let output = try? await git.run(["--version"], in: FileManager.default.temporaryDirectory), output.succeeded
        else { return nil }
        let line = output.stdout.split(separator: "\n").first.map(String.init) ?? ""
        let prefix = "git version "
        return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) : nil
    }

    public static func gitHubCLIVersion() async -> String? {
        guard let gh = GhCliProvider.locate(),
            let output = try? await CommandRunner(executable: gh, timeout: .seconds(10)).run(["--version"]), output.succeeded
        else { return nil }
        let line = output.stdout.split(separator: "\n").first.map(String.init) ?? ""
        let prefix = "gh version "
        guard line.hasPrefix(prefix) else { return nil }
        return line.dropFirst(prefix.count).split(separator: " ").first.map(String.init)
    }

    /// Plain sentences for what stops Lopper from working, for the report.
    public static func setupProblems(gitVersion: String?, folderAccess: [FolderAccess]) -> [String] {
        var problems: [String] = []
        if gitVersion == nil { problems.append("git is not installed (Apple's command line tools are missing)") }
        let blocked = folderAccess.filter { !$0.isReadable }.count
        if blocked > 0 { problems.append("\(blocked) of \(folderAccess.count) folders cannot be read") }
        return problems
    }
}
