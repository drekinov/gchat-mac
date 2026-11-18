import ChatModel
import ChatStore
import Foundation

public struct PolicyContext: Sendable {
    public var me: UserName
    public var focusedSpace: SpaceName?
    public var appIsActive: Bool
    public var firstSyncCompleted: Timestamp?
    public var participatingThreads: Set<ThreadName>

    public init(
        me: UserName, focusedSpace: SpaceName? = nil, appIsActive: Bool = true, firstSyncCompleted: Timestamp? = nil,
        participatingThreads: Set<ThreadName> = []
    ) {
        self.me = me
        self.focusedSpace = focusedSpace
        self.appIsActive = appIsActive
        self.firstSyncCompleted = firstSyncCompleted
        self.participatingThreads = participatingThreads
    }
}

/// The local approximation of Google's notification behaviour; the API doesn't expose per-thread follow state.
public enum NotificationPolicy {
    /// A space without a fetched setting behaves like `ALL` for DMs and `MAIN_CONVERSATIONS` otherwise.
    public static func effectiveLevel(for space: StoredSpace) -> NotificationLevel {
        if let setting = space.notificationSetting { return setting.level }
        return space.space.type == .directMessage ? .all : .mainConversations
    }

    public static func shouldNotify(_ message: Message, in space: StoredSpace, context: PolicyContext) -> Bool {
        guard !message.isDeleted, message.sender.name != context.me else { return false }
        guard let firstSync = context.firstSyncCompleted, message.createTime >= firstSync else { return false }
        if context.appIsActive, let focused = context.focusedSpace, focused == space.space.name { return false }
        if space.notificationSetting?.isMuted == true { return false }
        if isSilent(message) { return false }
        if let viewer = message.privateViewer, viewer != context.me { return false }

        switch effectiveLevel(for: space) {
        case .off:
            return false
        case .all:
            return true
        case .mainConversations:
            guard message.isThreadReply else { return true }
            return message.thread.map(context.participatingThreads.contains) ?? false
        case .forYou:
            return space.space.type == .directMessage || mentions(message, context.me)
        }
    }

    static func mentions(_ message: Message, _ user: UserName) -> Bool {
        message.annotations.contains { annotation in
            guard case .userMention(let mentioned) = annotation.kind else { return false }
            return mentioned == user || mentioned == .all
        }
    }

    /// `Message` has no `silent` field yet; this is where it is checked once it exists.
    private static func isSilent(_ message: Message) -> Bool { false }
}
