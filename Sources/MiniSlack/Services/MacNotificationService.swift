import AppKit
import Foundation
import UserNotifications

struct LocalMessageNotification: Sendable {
    let conversationID: String
    let conversationTitle: String
    let author: String
    let body: String
    let messageID: String
}

@MainActor
protocol MessageNotificationDelivering: AnyObject {
    var onOpenConversation: ((String) -> Void)? { get set }

    func requestAuthorizationIfNeeded() async
    func deliver(_ notification: LocalMessageNotification) async
}

@MainActor
protocol DockBadgeUpdating: AnyObject {
    func update(unreadCount: Int)
}

@MainActor
final class MacNotificationService: NSObject, MessageNotificationDelivering {
    static let shared = MacNotificationService()

    var onOpenConversation: ((String) -> Void)?

    private lazy var center: UNUserNotificationCenter? = {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return nil
        }
        return UNUserNotificationCenter.current()
    }()

    private override init() {
        super.init()
    }

    func configure() {
        center?.delegate = self
    }

    func requestAuthorizationIfNeeded() async {
        guard let center else {
            return
        }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else {
            return
        }
        _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func deliver(_ notification: LocalMessageNotification) async {
        guard let center else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = notification.conversationTitle
        content.subtitle = notification.author
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = notification.conversationID
        content.userInfo = ["conversationID": notification.conversationID]

        let request = UNNotificationRequest(
            identifier: "\(notification.conversationID)-\(notification.messageID)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}

extension MacNotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let conversationID =
            response.notification.request.content.userInfo["conversationID"] as? String
        completionHandler()
        Task { @MainActor [weak self] in
            if let conversationID {
                self?.onOpenConversation?(conversationID)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

@MainActor
final class MacDockBadgeService: DockBadgeUpdating {
    static let shared = MacDockBadgeService()

    private init() {}

    func update(unreadCount: Int) {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let application = NSApp
        else {
            return
        }
        application.dockTile.badgeLabel = DockBadgeFormatter.label(
            unreadCount: unreadCount
        )
    }
}
