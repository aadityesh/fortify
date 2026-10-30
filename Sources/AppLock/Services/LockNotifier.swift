import AppKit
import UserNotifications

/// The "‹App› locked" notification after the lock shortcut. Permission is asked
/// the first time it's needed.
@MainActor
final class LockNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let identifier = "lock-shortcut"
    private var center: UNUserNotificationCenter { .current() }

    override init() {
        super.init()
        center.delegate = self
    }

    func appLocked(_ app: NSRunningApplication) {
        let name = app.localizedName ?? "The app"
        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
            guard granted else {
                lockLog.notice("Lock shortcut notification not shown: notifications aren't allowed")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "\(name) locked"
            content.body = "Opening it again asks for your PIN."
            // One identifier: a newer lock replaces the last banner instead of stacking.
            try? await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
            // A confirmation, not something to keep: clear it from Notification Center.
            try? await Task.sleep(for: .seconds(8))
            center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        }
    }

    /// Shown as a banner even when Fortify My Mac is the active app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
