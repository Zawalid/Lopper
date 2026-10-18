import AppKit
import Observation
import Sparkle

/// What the Settings pane and the menu need from the updater, so they can be tested without Sparkle.
@MainActor
protocol UpdateChecking: AnyObject {
    /// Whether Lopper asks GitHub once a day if a newer version exists. Off until the person turns it on.
    var automaticallyChecks: Bool { get set }
    var canCheck: Bool { get }
    func checkNow()
}

/// In-app updates through Sparkle. The feed is the appcast attached to the latest GitHub release. Every update is
/// checked against the EdDSA public key in the app's Info.plist before anything is installed, and Sparkle always shows
/// the person what is new and waits for "Install Update". Checks are off until the person turns them on.
@MainActor
@Observable
final class AppUpdater: NSObject, UpdateChecking, SPUUpdaterDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    private var checksOn: Bool

    /// `startingUpdater` is false only in tests, which must not touch the real update preferences.
    init(startingUpdater: Bool = true) {
        checksOn = false
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: startingUpdater, updaterDelegate: self, userDriverDelegate: nil)
        checksOn = controller.updater.automaticallyChecksForUpdates
    }

    var automaticallyChecks: Bool {
        get { checksOn }
        set {
            checksOn = newValue
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var canCheck: Bool { controller.updater.canCheckForUpdates }

    func checkNow() { controller.checkForUpdates(nil) }

    #if DEBUG
    /// Debug builds only: point the updater at a local appcast to try an update without publishing one.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["LOPPER_FEED_URL"]
    }
    #endif
}
