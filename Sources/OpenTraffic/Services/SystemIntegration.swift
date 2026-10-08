import AppKit
import ServiceManagement
import UserNotifications

/// Posts user notifications. Silently does nothing when the process is not running
/// from an app bundle, because UNUserNotificationCenter traps without one.
@MainActor
enum TunnelNotifications {
    private static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private static let presenter = ForegroundPresenter()

    enum Category: String {
        case ready = "TUNNEL_READY"
        case failure = "TUNNEL_FAILURE"
    }

    enum ActionID {
        static let copy = "COPY_URL"
        static let stop = "STOP_TUNNEL"
        static let show = "SHOW_TUNNEL"
    }

    static func requestAuthorizationIfNeeded() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = presenter
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.ready.rawValue,
                actions: [
                    UNNotificationAction(identifier: ActionID.copy, title: "Copy URL"),
                    UNNotificationAction(identifier: ActionID.stop, title: "Stop", options: [.destructive]),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.failure.rawValue,
                actions: [UNNotificationAction(identifier: ActionID.show, title: "Show Details", options: [.foreground])],
                intentIdentifiers: []
            ),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, identifier: String, category: Category? = nil, tunnelID: UUID? = nil) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category.rawValue }
        if let tunnelID { content.userInfo = ["tunnelID": tunnelID.uuidString] }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// macOS hides banners for the frontmost app by default, which is exactly when the user
/// just clicked Share. Show them anyway.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    /// Copy URL, Stop, and Show Details buttons on OpenTraffic's notifications.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard let raw = response.notification.request.content.userInfo["tunnelID"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run {
            let store = AppStore.shared
            switch action {
            case TunnelNotifications.ActionID.copy:
                store.copyPublicURL(id)
            case TunnelNotifications.ActionID.stop:
                store.stop(id)
            default:
                // The notification itself or Show Details: bring up the tunnel.
                store.selectedID = id
                MainWindowController.shared.show {}
            }
        }
    }
}

/// Launch-at-login through the main-app SMAppService.
@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

enum Pasteboard {
    /// Concealed text carries the nspasteboard.org markers, so clipboard managers don't keep it in history.
    static func copy(_ text: String, concealed: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if concealed {
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        }
    }
}
