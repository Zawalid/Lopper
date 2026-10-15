import Foundation
import UserNotifications

/// When to tell the person what could be cleaned up. Once a week, and only when it is worth an interruption.
enum DigestPolicy {
    static let minimumBytes: Int64 = 1_000_000_000
    static let cadence: TimeInterval = 7 * 86_400

    static func shouldNotify(reclaimable: Int64, last: Date?, now: Date) -> Bool {
        guard reclaimable >= minimumBytes else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= cadence
    }

    static func message(
        safeItems: Int, itemBytes: Int64, folderBytes: Int64, agentsFinished: Int
    ) -> (title: String, body: String) {
        let total = itemBytes + folderBytes
        var parts: [String] = []
        if safeItems > 0 { parts.append("\(Plural.count(safeItems, "branch and worktree", "branches and worktrees")) are safe to remove") }
        if folderBytes > 0 { parts.append("\(SizeFormat.string(folderBytes)) sits in generated folders") }
        if agentsFinished > 0 { parts.append("\(Plural.count(agentsFinished, "agent worktree")) finished") }
        return ("\(SizeFormat.string(total)) can be given back", parts.joined(separator: ". ") + ".")
    }
}

protocol DigestNotifying: Sendable {
    func requestAuthorization() async -> Bool
    func send(title: String, body: String) async
}

struct SystemDigestNotifier: DigestNotifying {
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
    }

    func send(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "lopper.digest", content: content, trigger: nil)
        try? await center.add(request)
    }
}

/// Never sends anything. Used by tests and previews.
struct SilentDigestNotifier: DigestNotifying {
    func requestAuthorization() async -> Bool { false }
    func send(title: String, body: String) async {}
}
