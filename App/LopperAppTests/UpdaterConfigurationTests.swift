import XCTest
import AppKit
import SwiftUI
@testable import LopperApp

/// The update settings live in Info.plist, where a typo would not show until an update failed in the field.
final class UpdaterConfigurationTests: XCTestCase {
    private var info: [String: Any] { Bundle(for: AppUpdater.self).infoDictionary ?? [:] }

    func testTheFeedIsTheAppcastOnTheLatestGitHubRelease() throws {
        let feed = try XCTUnwrap(info["SUFeedURL"] as? String)

        XCTAssertEqual(feed, "https://github.com/Zawalid/Lopper/releases/latest/download/appcast.xml")
        XCTAssertEqual(URL(string: feed)?.scheme, "https", "updates are never fetched over plain http")
    }

    func testThePublicKeyIsAThirtyTwoByteEdDSAKey() throws {
        let key = try XCTUnwrap(info["SUPublicEDKey"] as? String)

        XCTAssertEqual(Data(base64Encoded: key)?.count, 32, "an Ed25519 public key is 32 bytes: \(key)")
    }

    func testCheckingNeverStartsOnItsOwnAndNothingInstallsSilently() {
        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, false, "off until the person turns it on")
        XCTAssertEqual(info["SUAllowsAutomaticUpdates"] as? Bool, false, "an update always waits for Install Update")
    }

    func testSparkleIsEmbeddedInTheApp() throws {
        let frameworks = try XCTUnwrap(Bundle(for: AppUpdater.self).privateFrameworksURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: frameworks.appendingPathComponent("Sparkle.framework").path))
    }

    @MainActor
    func testTheUpdaterCanBeCreatedWithoutStartingItOrTouchingThePreferences() {
        let updater = AppUpdater(startingUpdater: false)

        XCTAssertFalse(updater.canCheck, "an updater that was not started cannot check")
    }

    /// A snapshot of the real Settings window, General and About, so the update controls are drawn. Only runs when
    /// `LOPPER_SNAPSHOT_DIR` is set (pass it as `TEST_RUNNER_LOPPER_SNAPSHOT_DIR`).
    @MainActor
    func testWriteSnapshotsOfTheUpdateSettings() throws {
        guard let directory = ProcessInfo.processInfo.environment["LOPPER_SNAPSHOT_DIR"] else {
            throw XCTSkip("set LOPPER_SNAPSHOT_DIR to write snapshots")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let model = AppModel.preview(snapshots: [Fixtures.sample], history: [], route: .overview, clock: { Fixtures.now })
        let updater = AppUpdater(startingUpdater: false)
        for (name, pane) in [("general", SettingsPane.general), ("about", .about)] {
            let controller = NSHostingController(
                rootView: SettingsView(initialPane: pane).environment(model).environment(updater))
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(NSSize(width: 620, height: 560))
            window.appearance = NSAppearance(named: .darkAqua)
            window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(directory)/settings-\(name)-updates.png"))
            }
            window.close()
        }
    }
}
