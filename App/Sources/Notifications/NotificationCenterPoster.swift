import AppKit
import ChatModel
import ChatSync
import Foundation
@preconcurrency import UserNotifications

/// Posts the core's notifications through `UNUserNotificationCenter`. Everything shown passes through `RemoteText`.
final class NotificationCenterPoster: NotificationPoster {
    static let enabledKey = "notificationsEnabled"
    static let promptedKey = "notificationsPrompted"
    static let fakeKey = "fakeNotifications"

    let isFake: Bool

    init(isFake: Bool) { self.isFake = isFake }

    /// Fake worlds only notify when the Developer setting is on, so traffic never spams by default.
    private var allowed: Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.enabledKey) else { return false }
        return !isFake || defaults.bool(forKey: Self.fakeKey)
    }

    func post(_ request: ChatNotification) async {
        guard allowed else { return }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = RemoteText.title(request.title)
        content.body = RemoteText.clean(request.body, limit: 200, keepLineBreaks: false)
        content.threadIdentifier = request.threadIdentifier
        content.userInfo = ["account": request.account.description, "space": request.space.rawValue]
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
    }

    func remove(account: AccountID) async {
        let center = UNUserNotificationCenter.current()
        let target = account.description
        let delivered = await center.deliveredNotifications()
        let identifiers = delivered.filter { $0.request.content.userInfo["account"] as? String == target }
            .map(\.request.identifier)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.filter { $0.content.userInfo["account"] as? String == target }.map(\.identifier))
    }

    func remove(messages: [MessageName]) async {
        let identifiers = messages.map(\.rawValue)
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    // MARK: Authorization

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks for permission once, on the first launch. A grant also turns the in-app switch on.
    static func requestOnFirstLaunch() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: promptedKey) else { return }
        defaults.set(true, forKey: promptedKey)
        _ = await requestAuthorization()
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        let granted =
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]))
            ?? false
        UserDefaults.standard.set(granted, forKey: enabledKey)
        return granted
    }
}

/// Handles clicks on delivered notifications and decides how they present while the app runs.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let open: @Sendable (String, String) -> Void

    init(open: @escaping @Sendable (String, String) -> Void) {
        self.open = open
        super.init()
    }

    @MainActor
    static func install(model: AppModel) -> NotificationResponder {
        let responder = NotificationResponder { account, space in
            Task { @MainActor in model.openFromNotification(account: account, space: space) }
        }
        UNUserNotificationCenter.current().delegate = responder
        return responder
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let account = info["account"] as? String, let space = info["space"] as? String else { return }
        open(account, space)
    }
}
