import XCTest
@testable import Lopper

final class ArtifactRulesTests: XCTestCase {
    private func evaluate(_ name: String, files: Set<String>) -> ArtifactRules.Evaluation {
        let project = URL(fileURLWithPath: "/work/app")
        return ArtifactRules.evaluate(
            name: name, projectDirectory: project, checkoutRoot: project,
            fileExists: { files.contains($0.lastPathComponent) }, readText: { _ in nil })
    }

    func testNodeModulesNeedsALockfileAndNamesTheRightInstallCommand() {
        XCTAssertEqual(evaluate("node_modules", files: ["package-lock.json"]).removal, .offered(regenerate: "npm ci"))
        XCTAssertEqual(evaluate("node_modules", files: ["pnpm-lock.yaml"]).removal, .offered(regenerate: "pnpm install"))
        XCTAssertEqual(evaluate("node_modules", files: ["yarn.lock"]).removal, .offered(regenerate: "yarn install"))
        XCTAssertEqual(evaluate("node_modules", files: ["bun.lockb"]).removal, .offered(regenerate: "bun install"))
        XCTAssertEqual(evaluate("node_modules", files: ["package.json"]).kind, .packages)
        if case .blocked = evaluate("node_modules", files: ["package.json"]).removal {} else {
            XCTFail("without a lockfile reinstalling could pull different versions")
        }
    }

    func testFrameworkCachesNeedAPackageJson() {
        for name in [".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".vite", ".angular"] {
            XCTAssertEqual(evaluate(name, files: ["package.json"]).kind, .frameworkCache, name)
            if case .offered = evaluate(name, files: ["package.json"]).removal {} else { XCTFail(name) }
            if case .blocked = evaluate(name, files: []).removal {} else { XCTFail("\(name) without package.json") }
        }
    }

    func testGenericBuildFoldersNeedToBeRecognisablyRebuildable() {
        XCTAssertEqual(evaluate("dist", files: ["package.json"]).removal, .offered(regenerate: "your build script"))
        XCTAssertEqual(evaluate("build", files: ["build.gradle.kts"]).removal, .offered(regenerate: "gradle build"))
        XCTAssertEqual(evaluate("build", files: ["Makefile"]).removal, .offered(regenerate: "make"))
        if case .blocked = evaluate("build", files: []).removal {} else {
            XCTFail("a build folder in a project Lopper cannot identify is not offered")
        }
    }

    func testLanguageSpecificFolders() {
        XCTAssertEqual(evaluate("target", files: ["Cargo.toml"]).removal, .offered(regenerate: "cargo build"))
        XCTAssertEqual(evaluate("target", files: ["pom.xml"]).removal, .offered(regenerate: "mvn package"))
        XCTAssertEqual(evaluate(".build", files: ["Package.swift"]).removal, .offered(regenerate: "swift build"))
        XCTAssertEqual(evaluate("Pods", files: ["Podfile.lock"]).removal, .offered(regenerate: "pod install"))
        XCTAssertEqual(evaluate(".venv", files: ["uv.lock"]).kind, .pythonEnvironment)
        XCTAssertEqual(evaluate("DerivedData", files: []).removal, .offered(regenerate: "your next Xcode build"))
        if case .blocked = evaluate("target", files: []).removal {} else { XCTFail("target with no manifest") }
    }

    func testPlainCachesAreAlwaysOffered() {
        for name in ["__pycache__", ".pytest_cache", ".ruff_cache", ".mypy_cache", ".tox", "coverage", ".cache"] {
            XCTAssertEqual(evaluate(name, files: []).kind, .cache, name)
            if case .offered = evaluate(name, files: []).removal {} else { XCTFail(name) }
        }
    }

    func testAnUnknownNameYouListedYourselfIsOfferedAsYourOwnChoice() {
        let result = evaluate("my-generated", files: [])

        XCTAssertEqual(result.kind, .other)
        XCTAssertEqual(result.removal, .offered(regenerate: "whatever produces it"))
    }

    func testEveryKindHasAReadableTitle() {
        for kind in ArtifactKind.allCases {
            XCTAssertFalse(kind.title.isEmpty, "\(kind)")
        }
    }
}
