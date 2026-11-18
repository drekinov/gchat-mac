import ChatModel
import ChatSync
import Foundation

struct SpaceKey: Hashable, Sendable {
    let account: AccountID
    let space: SpaceName
}

struct AccountInfo: Identifiable, Hashable, Sendable {
    let id: AccountID
    /// The user's label for the account, or its email.
    var name: String
    let colorIndex: Int
    let me: UserName
    var email: String? = nil
}

struct InboxEntry: Identifiable, Hashable {
    let account: AccountID
    let summary: SpaceSummary

    var id: SpaceKey { SpaceKey(account: account, space: summary.name) }
    var isMuted: Bool { summary.isMuted }
    var unread: Int { summary.unreadCount }
    var hasUnread: Bool { unread > 0 }
}

enum SpaceKind {
    case space, directMessage, group, bot
}

/// One composer: the space's main composer (`thread == nil`) or a thread reply composer.
struct ComposerID: Hashable {
    let key: SpaceKey
    let thread: ThreadName?
}

/// Asks the open message list to scroll; used by the benchmark.
struct ScrollCommand: Equatable {
    var sequence: Int
    var toTop: Bool
}
