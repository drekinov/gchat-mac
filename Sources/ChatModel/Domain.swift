import Foundation

/// Local, opaque account identifier. Directories and keychain items are keyed by it, never by email.
public struct AccountID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }

    public var description: String { rawValue.uuidString.lowercased() }
}

public enum SpaceType: String, Sendable, Codable {
    case space = "SPACE"
    case groupChat = "GROUP_CHAT"
    case directMessage = "DIRECT_MESSAGE"
}

public struct Space: Hashable, Sendable, Codable, Identifiable {
    public var name: SpaceName
    public var type: SpaceType
    /// Empty for DMs and unnamed group chats; their titles come from members.
    public var displayName: String
    public var isSingleUserBotDM: Bool
    public var isThreaded: Bool
    public var lastActiveTime: Timestamp?
    public var createTime: Timestamp?
    public var isExternalUserAllowed: Bool
    /// `spaceHistoryState`: on keeps messages under the org's retention rules, off deletes them after about 24 hours.
    public var historyOn: Bool?

    public var id: SpaceName { name }

    public init(
        name: SpaceName, type: SpaceType, displayName: String = "", isSingleUserBotDM: Bool = false,
        isThreaded: Bool = true, lastActiveTime: Timestamp? = nil, createTime: Timestamp? = nil,
        isExternalUserAllowed: Bool = false, historyOn: Bool? = nil
    ) {
        self.name = name
        self.type = type
        self.displayName = displayName
        self.isSingleUserBotDM = isSingleUserBotDM
        self.isThreaded = isThreaded
        self.lastActiveTime = lastActiveTime
        self.createTime = createTime
        self.isExternalUserAllowed = isExternalUserAllowed
        self.historyOn = historyOn
    }
}

public enum UserType: String, Sendable, Codable {
    case human = "HUMAN"
    case bot = "BOT"
}

public struct User: Hashable, Sendable, Codable {
    public var name: UserName
    public var type: UserType
    /// Only populated for co-members or users with prior affinity.
    public var displayName: String?
    public var isAnonymous: Bool

    public init(name: UserName, type: UserType = .human, displayName: String? = nil, isAnonymous: Bool = false) {
        self.name = name
        self.type = type
        self.displayName = displayName
        self.isAnonymous = isAnonymous
    }
}

public struct Membership: Hashable, Sendable, Codable {
    public enum Role: String, Sendable, Codable {
        case member = "ROLE_MEMBER"
        case manager = "ROLE_MANAGER"
        case assistantManager = "ROLE_ASSISTANT_MANAGER"
        case unspecified = "MEMBERSHIP_ROLE_UNSPECIFIED"

        /// An unknown stored role reads as unspecified, so one row can't fail the whole members list.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Role(rawValue: raw) ?? .unspecified
        }
    }

    public enum State: String, Sendable, Codable {
        case joined = "JOINED"
        case invited = "INVITED"
        case notAMember = "NOT_A_MEMBER"
        case unspecified = "MEMBERSHIP_STATE_UNSPECIFIED"
    }

    public var name: MembershipName
    public var member: User
    public var role: Role
    public var state: State

    public init(name: MembershipName, member: User, role: Role = .member, state: State = .joined) {
        self.name = name
        self.member = member
        self.role = role
        self.state = state
    }
}

/// Offsets and lengths are in UTF-16 code units of `Message.text`.
public struct Annotation: Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable, Codable {
        case userMention(UserName)
        case slashCommand
        case richLink(URL)
        case customEmoji(CustomEmojiName?, shortcode: String?)
    }

    public var kind: Kind
    public var startIndex: Int
    public var length: Int

    public init(kind: Kind, startIndex: Int, length: Int) {
        self.kind = kind
        self.startIndex = startIndex
        self.length = length
    }
}

public struct Attachment: Hashable, Sendable, Codable {
    public enum Source: Hashable, Sendable, Codable {
        /// Fetchable with the bearer token via `media.download`.
        case uploaded(MediaResourceName)
        /// Opened in the browser only.
        case drive(fileID: String)
    }

    public var contentName: String
    public var contentType: String
    public var source: Source
    /// Browser links; never fetched by the app.
    public var thumbnailURI: URL?
    public var downloadURI: URL?

    public init(
        contentName: String, contentType: String, source: Source, thumbnailURI: URL? = nil, downloadURI: URL? = nil
    ) {
        self.contentName = contentName
        self.contentType = contentType
        self.source = source
        self.thumbnailURI = thumbnailURI
        self.downloadURI = downloadURI
    }
}

public enum Emoji: Hashable, Sendable, Codable {
    case unicode(String)
    case custom(CustomEmojiName, shortcode: String?)
}

public struct ReactionSummary: Hashable, Sendable, Codable {
    public var emoji: Emoji
    public var count: Int

    public init(emoji: Emoji, count: Int) {
        self.emoji = emoji
        self.count = count
    }
}

public struct QuotedMessage: Hashable, Sendable, Codable {
    public var name: MessageName
    public var lastUpdateTime: Timestamp?
    public var snapshotSender: UserName?
    public var snapshotText: String?

    public init(
        name: MessageName, lastUpdateTime: Timestamp? = nil, snapshotSender: UserName? = nil,
        snapshotText: String? = nil
    ) {
        self.name = name
        self.lastUpdateTime = lastUpdateTime
        self.snapshotSender = snapshotSender
        self.snapshotText = snapshotText
    }
}

public struct Message: Hashable, Sendable, Codable, Identifiable {
    public var name: MessageName
    public var sender: User
    public var createTime: Timestamp
    public var lastUpdateTime: Timestamp?
    /// Set on tombstones (`showDeleted`, deleted events).
    public var deleteTime: Timestamp?
    public var text: String
    /// Google's Chat-syntax markup for `text`; nil on tombstones and on rows cached before it was stored.
    public var formattedText: String?
    public var annotations: [Annotation]
    public var thread: ThreadName?
    public var isThreadReply: Bool
    public var attachments: [Attachment]
    public var gifURLs: [URL]
    public var reactions: [ReactionSummary]
    public var quoted: QuotedMessage?
    /// Plain-text stand-in for cards, which are rendered read-only.
    public var cardsFallbackText: String?
    /// Optional so rows stored before cards existed still decode.
    public var cards: [Card]?
    public var privateViewer: UserName?
    public var clientMessageID: String?

    public var id: MessageName { name }
    public var space: SpaceName { name.space }
    public var isDeleted: Bool { deleteTime != nil }

    /// Version stamp for overlap dedupe: a copy replaces another only if it isn't older.
    public var version: Timestamp { max(deleteTime ?? createTime, lastUpdateTime ?? createTime) }

    /// The copy to keep when `incoming` meets `stored`, or nil to keep `stored`. Deletes are terminal: a live copy
    /// never replaces a tombstone, and a tombstone keeps the sender and thread that Google's sparse deletion events
    /// leave out. An equal copy with the same text fills in markup with its annotations, or keeps the stored markup.
    public static func merge(_ incoming: Message, over stored: Message?, rewriteEqual: Bool = false) -> Message? {
        guard let stored else { return incoming.isDeleted ? incoming.withoutMarkup : incoming }
        switch (stored.isDeleted, incoming.isDeleted) {
        case (true, false):
            return nil
        case (false, true):
            return incoming.keepingIdentity(of: stored)
        case (true, true):
            return incoming.version < stored.version ? nil : incoming.keepingIdentity(of: stored)
        case (false, false):
            if incoming.version < stored.version { return nil }
            guard incoming.version == stored.version else { return incoming }
            let sameText = incoming.text == stored.text
            if rewriteEqual {
                guard sameText, incoming.formattedText == nil, stored.formattedText != nil else { return incoming }
                var kept = incoming
                kept.formattedText = stored.formattedText
                return kept
            }
            guard sameText, let markup = incoming.formattedText,
                markup != stored.formattedText || incoming.annotations != stored.annotations
            else { return nil }
            var backfilled = stored
            backfilled.formattedText = markup
            backfilled.annotations = incoming.annotations
            return backfilled
        }
    }

    /// Whether an equal-version live `incoming` can change a live stored row, which only `merge` can tell after
    /// decoding it. Lets a store skip decoding rows the merge would leave alone.
    public static func equalCopyNeedsStored(_ incoming: Message, rewriteEqual: Bool) -> Bool {
        rewriteEqual ? incoming.formattedText == nil : incoming.formattedText != nil
    }

    private var withoutMarkup: Message {
        var copy = self
        copy.formattedText = nil
        return copy
    }

    private func keepingIdentity(of stored: Message) -> Message {
        var merged = withoutMarkup
        merged.sender = stored.sender
        merged.thread = stored.thread ?? thread
        merged.isThreadReply = stored.isThreadReply
        return merged
    }

    public init(
        name: MessageName, sender: User, createTime: Timestamp, lastUpdateTime: Timestamp? = nil,
        deleteTime: Timestamp? = nil, text: String = "", formattedText: String? = nil, annotations: [Annotation] = [],
        thread: ThreadName? = nil,
        isThreadReply: Bool = false, attachments: [Attachment] = [], gifURLs: [URL] = [],
        reactions: [ReactionSummary] = [], quoted: QuotedMessage? = nil, cardsFallbackText: String? = nil,
        cards: [Card]? = nil, privateViewer: UserName? = nil, clientMessageID: String? = nil
    ) {
        self.name = name
        self.sender = sender
        self.createTime = createTime
        self.lastUpdateTime = lastUpdateTime
        self.deleteTime = deleteTime
        self.text = text
        self.formattedText = formattedText
        self.annotations = annotations
        self.thread = thread
        self.isThreadReply = isThreadReply
        self.attachments = attachments
        self.gifURLs = gifURLs
        self.reactions = reactions
        self.quoted = quoted
        self.cardsFallbackText = cardsFallbackText
        self.cards = cards
        self.privateViewer = privateViewer
        self.clientMessageID = clientMessageID
    }
}

public enum NotificationLevel: String, Sendable, Codable, CaseIterable {
    case all = "ALL"
    case mainConversations = "MAIN_CONVERSATIONS"
    case forYou = "FOR_YOU"
    case off = "OFF"
}

public struct SpaceNotificationSetting: Hashable, Sendable, Codable {
    public var level: NotificationLevel
    public var isMuted: Bool

    public init(level: NotificationLevel, isMuted: Bool) {
        self.level = level
        self.isMuted = isMuted
    }
}

/// One entry from `spaces.spaceEvents.list`, with batch variants flattened by the client.
public enum SpaceEvent: Hashable, Sendable {
    case messageCreated(Message)
    case messageUpdated(Message)
    case messageDeleted(Message)
    case reactionsChanged(MessageName)
    case membershipsChanged
    case spaceUpdated(Space)

    public static let pollTypes = [
        "google.workspace.chat.message.v1.created", "google.workspace.chat.message.v1.updated",
        "google.workspace.chat.message.v1.deleted", "google.workspace.chat.reaction.v1.created",
        "google.workspace.chat.reaction.v1.deleted", "google.workspace.chat.membership.v1.created",
        "google.workspace.chat.membership.v1.updated", "google.workspace.chat.membership.v1.deleted",
        "google.workspace.chat.space.v1.updated",
    ]
}

public struct TimedSpaceEvent: Hashable, Sendable {
    public var time: Timestamp
    public var event: SpaceEvent

    public init(time: Timestamp, event: SpaceEvent) {
        self.time = time
        self.event = event
    }
}

public struct Page<Item: Sendable>: Sendable {
    public var items: [Item]
    public var nextPageToken: String?
    /// Required records dropped because they were malformed; a page with skips isn't a complete account of its range.
    public var skipped: Int

    public init(items: [Item], nextPageToken: String?, skipped: Int = 0) {
        self.items = items
        self.nextPageToken = nextPageToken
        self.skipped = skipped
    }
}

extension Page: Equatable where Item: Equatable {}

extension Message {
    /// The newest of `replies` whose name is in `visible`, leaving out deleted ones; what an open thread has read.
    public static func newestVisibleReply(in replies: [Message], visible: Set<MessageName>) -> Timestamp? {
        guard !visible.isEmpty else { return nil }
        return replies.lazy.filter { $0.isThreadReply && !$0.isDeleted && visible.contains($0.name) }.map(\.createTime)
            .max()
    }
}
