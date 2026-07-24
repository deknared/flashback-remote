import Foundation
import UserNotifications

// Local notifications (no server / push entitlement needed) so the user gets
// alerted when a long transfer finishes while the app is backgrounded.
enum Notifier {
    private static var didRequestAuthorization = false

    /// Called once at launch. Guarded so repeated calls (e.g. one per transfer,
    /// as this used to be) don't re-enter the authorization API needlessly.
    static func requestAuthorization() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyDownloadComplete(count: Int, deleted: Int) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Transfer complete"
            var body = "\(count) file\(count == 1 ? "" : "s") saved"
            if deleted > 0 { body += ", \(deleted) deleted from camera" }
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            center.add(request)
        }
    }
}
