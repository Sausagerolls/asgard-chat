import AsgardKit
import Intents
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let siri = SiriIntentHandler()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated { AppServices.shared.calls.registerVoIP() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await AppServices.shared.engine.registerPush(token: deviceToken, voipToken: nil) }
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await AppServices.shared.engine.syncNow()
        return .newData
    }

    /// In-app SiriKit handling (no separate Intents extension needed).
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        switch intent {
        case is INSendMessageIntent, is INSearchForMessagesIntent, is INSetMessageAttributeIntent, is INStartCallIntent: siri
        default: nil
        }
    }

    // MARK: Notifications

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let conv = (notification.request.content.userInfo["c"] as? String).flatMap(UUID.init(uuidString:))
        let active = await MainActor.run { AppServices.shared.engine.activeConversation }
        if conv != nil && conv == active { return [] }
        return UserDefaults.standard.object(forKey: "inAppBanners") as? Bool ?? true ? [.banner, .sound, .list] : [.list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let conv = (info["c"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        await MainActor.run {
            let engine = AppServices.shared.engine
            switch response.actionIdentifier {
            case Notifications.reply:
                if let text = (response as? UNTextInputNotificationResponse)?.userText, !text.isEmpty {
                    Task { await engine.start(); await engine.send(.text(text), to: conv); engine.markRead(conv) }
                }
            case Notifications.markRead:
                Task { await engine.start(); await engine.syncNow(); engine.markRead(conv) }
            case Notifications.like:
                Task {
                    await engine.start()
                    await engine.syncNow()
                    if let mid = (info["m"] as? String).flatMap(UUID.init(uuidString:)),
                       let m = try? engine.context.fetch(FetchDescriptorFactory.message(mid)).first { await engine.react("❤️", to: m) }
                }
            default:
                AppServices.shared.router.openConversation = conv
                AppServices.shared.router.selectedTab = .chats
            }
        }
    }
}

@MainActor
final class PushRegistrar {
    static let shared = PushRegistrar()
    func register() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-noPush") { return } // screenshots
        #endif
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound, .providesAppNotificationSettings])) ?? false
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        }
    }
}

enum Notifications {
    static let reply = "REPLY", markRead = "MARK_READ", like = "LIKE", messageCategory = "MESSAGE"

    static func registerCategories() {
        let reply = UNTextInputNotificationAction(identifier: reply, title: "Reply", options: [], icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let read = UNNotificationAction(identifier: markRead, title: "Mark as read", options: [], icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let like = UNNotificationAction(identifier: like, title: "❤️", options: [])
        let cat = UNNotificationCategory(identifier: messageCategory, actions: [reply, like, read], intentIdentifiers: [INSendMessageIntentIdentifier],
                                         options: [.allowAnnouncement, .hiddenPreviewsShowTitle])
        UNUserNotificationCenter.current().setNotificationCategories([cat])
    }
}
