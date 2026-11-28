import ChatModel
import ChatSync
import ChatText
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

extension ComposerID {
    var draftKey: DraftKey { DraftKey(space: key.space, thread: thread) }
}

/// Asks the open message list to scroll; used by the benchmark.
struct ScrollCommand: Equatable {
    var sequence: Int
    var toTop: Bool
}

/// Asks a composer to edit one message. `id` tells attempts apart, so a late result can't end a newer edit.
struct EditRequest: Equatable {
    let id = UUID()
    let message: MessageName
    var started = false
}

/// The draft a composer held when an edit started, given back when the edit ends.
struct StashedDraft {
    var text: String
    var mentions: MentionEditor
}

enum EditFailure: Error {
    case changed(Message)
    case message(String)
}

/// A delete waiting for confirmation. `force` also deletes a thread starter's replies.
struct DeleteRequest: Identifiable {
    let key: SpaceKey
    let message: Message
    let force: Bool
    var id: MessageName { message.name }
}

/// Which member list the open space's role was read from.
struct RoleSource: Equatable {
    let key: SpaceKey
    let fetched: Timestamp?
}
