import Foundation

/// What sort of generated folder something is. Used to group them and to say how each one comes back.
public enum ArtifactKind: String, Sendable, CaseIterable, Equatable {
    case packages
    case frameworkCache
    case buildOutput
    case languageBuild
    case pythonEnvironment
    case cache
    case other

    public var title: String {
        switch self {
        case .packages: "Installed packages"
        case .frameworkCache: "Framework caches"
        case .buildOutput: "Build output"
        case .languageBuild: "Compiler and tool builds"
        case .pythonEnvironment: "Python environments"
        case .cache: "Caches"
        case .other: "Other generated folders"
        }
    }
}

public enum ArtifactRemoval: Sendable, Equatable {
    /// Can be cleared; `regenerate` says what brings it back.
    case offered(regenerate: String)
    /// Lopper will not offer it, and says why.
    case blocked(reason: String)

    public var isOffered: Bool {
        if case .offered = self { true } else { false }
    }
}

public enum ArtifactLocation: Sendable, Equatable {
    case mainCheckout
    case worktree(branch: String?)
    /// A tool's cache in the home folder (Xcode build data, the npm cache, ...), not inside any repository.
    case developerCache
}

/// One generated folder inside a checkout, found through git and safe to describe.
public struct DiskArtifact: Sendable, Equatable, Identifiable {
    public var id: String { path.path }
    public let path: URL
    public let name: String
    public let kind: ArtifactKind
    public let bytes: Int64
    public let newestModification: Date?
    /// The folder the artifact sits in, which holds the manifest and lockfile that bring it back.
    public let projectDirectory: URL
    /// The working folder of the checkout (main folder or worktree) this lives in.
    public let checkoutRoot: URL
    /// The repository it belongs to.
    public let repoRoot: URL
    public let location: ArtifactLocation
    public let removal: ArtifactRemoval

    public init(
        path: URL, name: String, kind: ArtifactKind, bytes: Int64, newestModification: Date?,
        projectDirectory: URL, checkoutRoot: URL, repoRoot: URL, location: ArtifactLocation,
        removal: ArtifactRemoval
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.bytes = bytes
        self.newestModification = newestModification
        self.projectDirectory = projectDirectory
        self.checkoutRoot = checkoutRoot
        self.repoRoot = repoRoot
        self.location = location
        self.removal = removal
    }
}

/// The knowledge of which generated folder needs what before Lopper will offer to clear it. A folder is only
/// offered when Lopper can say how it comes back, so clearing never leaves a project that cannot be rebuilt.
enum ArtifactRules {
    struct Evaluation: Equatable {
        let kind: ArtifactKind
        let removal: ArtifactRemoval
    }

    private static let nodeLockfiles: [(file: String, command: String)] = [
        ("package-lock.json", "npm ci"), ("npm-shrinkwrap.json", "npm ci"),
        ("pnpm-lock.yaml", "pnpm install"), ("yarn.lock", "yarn install"),
        ("bun.lockb", "bun install"), ("bun.lock", "bun install"),
    ]
    private static let frameworkCaches: Set<String> = [
        ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".vite", ".angular",
    ]
    private static let plainCaches: Set<String> = [
        "__pycache__", ".pytest_cache", ".ruff_cache", ".mypy_cache", ".tox", "coverage", ".cache",
    ]

    static func evaluate(
        name: String, projectDirectory: URL, checkoutRoot: URL? = nil,
        fileExists: (URL) -> Bool, readText: (URL) -> String?
    ) -> Evaluation {
        func has(_ file: String) -> Bool { fileExists(projectDirectory.appendingPathComponent(file)) }
        func offered(_ kind: ArtifactKind, _ how: String) -> Evaluation { Evaluation(kind: kind, removal: .offered(regenerate: how)) }
        func blocked(_ kind: ArtifactKind, _ why: String) -> Evaluation { Evaluation(kind: kind, removal: .blocked(reason: why)) }

        switch name {
        case "node_modules":
            if let command = nodeInstallCommand(
                projectDirectory: projectDirectory, checkoutRoot: checkoutRoot, fileExists: fileExists, readText: readText)
            {
                return offered(.packages, command)
            }
            return blocked(.packages, "There is no lockfile, so reinstalling could pull different versions.")
        case let name where frameworkCaches.contains(name):
            return has("package.json")
                ? offered(.frameworkCache, "your next build or dev run")
                : blocked(.frameworkCache, "Not a Node project, so Lopper does not know how this is rebuilt.")
        case "dist", "build", "out":
            if has("package.json") { return offered(.buildOutput, "your build script") }
            if has("build.gradle") || has("build.gradle.kts") { return offered(.buildOutput, "gradle build") }
            if has("pom.xml") { return offered(.buildOutput, "mvn package") }
            if has("Makefile") || has("CMakeLists.txt") { return offered(.buildOutput, "make") }
            return blocked(.buildOutput, "Lopper cannot tell how this folder is rebuilt.")
        case "target":
            if has("Cargo.toml") { return offered(.languageBuild, "cargo build") }
            if has("pom.xml") { return offered(.languageBuild, "mvn package") }
            return blocked(.languageBuild, "No Cargo.toml or pom.xml here, so Lopper cannot tell how this is rebuilt.")
        case ".build":
            return has("Package.swift")
                ? offered(.languageBuild, "swift build")
                : blocked(.languageBuild, "No Package.swift here, so Lopper cannot tell how this is rebuilt.")
        case "DerivedData":
            return offered(.languageBuild, "your next Xcode build")
        case "Pods":
            return has("Podfile.lock")
                ? offered(.languageBuild, "pod install")
                : blocked(.languageBuild, "There is no Podfile.lock, so reinstalling could pull different versions.")
        case ".gradle":
            let hasGradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"].contains(where: has)
            return hasGradle
                ? offered(.languageBuild, "your next gradle run")
                : blocked(.languageBuild, "No Gradle build file here, so Lopper cannot tell how this is rebuilt.")
        case ".venv", "venv":
            let hasManifest = ["requirements.txt", "pyproject.toml", "Pipfile.lock", "poetry.lock", "uv.lock"].contains(where: has)
            return hasManifest
                ? offered(.pythonEnvironment, "your environment tool")
                : blocked(.pythonEnvironment, "No requirements file here, so the environment could not be recreated.")
        case let name where plainCaches.contains(name):
            return offered(.cache, "automatically, the next time it is needed")
        default:
            // A name the person added to their own throwaway list: their choice, taken at its word.
            return offered(.other, "whatever produces it")
        }
    }

    /// A lockfile beside the folder, or, for a workspace member, the one at the workspace root.
    private static func nodeInstallCommand(
        projectDirectory: URL, checkoutRoot: URL?, fileExists: (URL) -> Bool, readText: (URL) -> String?
    ) -> String? {
        func command(in directory: URL) -> String? {
            nodeLockfiles.first { fileExists(directory.appendingPathComponent($0.file)) }?.command
        }
        if let own = command(in: projectDirectory) { return own }
        guard let checkoutRoot else { return nil }

        var directory = projectDirectory.deletingLastPathComponent()
        let rootPath = checkoutRoot.standardizedFileURL.path
        while directory.standardizedFileURL.path.hasPrefix(rootPath), directory.path.count >= rootPath.count {
            if let inherited = command(in: directory), isWorkspaceRoot(directory, fileExists: fileExists, readText: readText) {
                return inherited
            }
            if directory.standardizedFileURL.path == rootPath { break }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    private static func isWorkspaceRoot(
        _ directory: URL, fileExists: (URL) -> Bool, readText: (URL) -> String?
    ) -> Bool {
        if fileExists(directory.appendingPathComponent("pnpm-workspace.yaml")) { return true }
        guard let text = readText(directory.appendingPathComponent("package.json")) else { return false }
        return text.contains("\"workspaces\"")
    }
}

/// Finds generated folders in one checkout. Discovery asks git which directories it ignores, so a folder that
/// merely has a familiar name, or is tracked on purpose, is never reported.
public struct ArtifactScanner: Sendable {
    private let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    public func scan(
        root: URL, repoRoot: URL, names: Set<String>, location: ArtifactLocation
    ) async -> [DiskArtifact] {
        guard let listing = try? await git.run(
            ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"], in: root),
            listing.succeeded else { return [] }

        var artifacts: [DiskArtifact] = []
        for entry in listing.stdout.split(separator: "\0") where entry.hasSuffix("/") {
            let relative = String(entry.dropLast())
            let url = root.appendingPathComponent(relative, isDirectory: true)
            let name = url.lastPathComponent
            guard GitParsers.matchesDisposable(name, names) else { continue }

            // Never follow a link out of the checkout, and never offer one.
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes?[.type] as? FileAttributeType == .typeDirectory else { continue }

            let project = url.deletingLastPathComponent()
            let evaluation = ArtifactRules.evaluate(
                name: name, projectDirectory: project, checkoutRoot: root,
                fileExists: { FileManager.default.fileExists(atPath: $0.path) },
                readText: { try? String(contentsOf: $0, encoding: .utf8) })
            let usage = await Self.measure(url)
            artifacts.append(DiskArtifact(
                path: url, name: name, kind: evaluation.kind, bytes: usage.bytes,
                newestModification: usage.newest, projectDirectory: project, checkoutRoot: root,
                repoRoot: repoRoot, location: location, removal: evaluation.removal))
        }
        return artifacts.sorted { $0.bytes > $1.bytes }
    }

    private static func measure(_ directory: URL) async -> (bytes: Int64, newest: Date?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let keys: [URLResourceKey] = [
                    .totalFileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey,
                ]
                guard let enumerator = FileManager.default.enumerator(
                    at: directory, includingPropertiesForKeys: keys, options: [])
                else { return continuation.resume(returning: (0, nil)) }
                var bytes: Int64 = 0
                var newest: Date?
                for case let url as URL in enumerator {
                    guard let values = try? url.resourceValues(forKeys: Set(keys)),
                          values.isRegularFile == true else { continue }
                    bytes += Int64(values.totalFileAllocatedSize ?? 0)
                    if let modified = values.contentModificationDate, newest.map({ modified > $0 }) ?? true {
                        newest = modified
                    }
                }
                continuation.resume(returning: (bytes, newest))
            }
        }
    }
}
