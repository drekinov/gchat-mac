import ChatModel
import Foundation

struct ReactionRecord: Sendable {
    var name: String
    var user: User
    var emoji: Emoji
}

struct MessageRecord: Sendable {
    var message: Message
    var reactions: [ReactionRecord] = []
    /// Set when the message was posted with history off: Google deletes it then, without an event.
    var expires: Timestamp? = nil
}

struct StoredEvent: Sendable {
    enum Payload: Sendable {
        case messageCreated(Message)
        case messageUpdated(Message)
        case messageDeleted(Message)
        case reactionCreated(ReactionRecord)
        case reactionDeleted(ReactionRecord)
        case membershipCreated(Membership)
        case membershipDeleted(Membership)
        case spaceUpdated(Space)

        var action: String {
            switch self {
            case .messageCreated, .reactionCreated, .membershipCreated: "Created"
            case .messageUpdated, .spaceUpdated: "Updated"
            case .messageDeleted, .reactionDeleted, .membershipDeleted: "Deleted"
            }
        }

        var eventType: String {
            switch self {
            case .messageCreated: "google.workspace.chat.message.v1.created"
            case .messageUpdated: "google.workspace.chat.message.v1.updated"
            case .messageDeleted: "google.workspace.chat.message.v1.deleted"
            case .reactionCreated: "google.workspace.chat.reaction.v1.created"
            case .reactionDeleted: "google.workspace.chat.reaction.v1.deleted"
            case .membershipCreated: "google.workspace.chat.membership.v1.created"
            case .membershipDeleted: "google.workspace.chat.membership.v1.deleted"
            case .spaceUpdated: "google.workspace.chat.space.v1.updated"
            }
        }

        var message: MessageName? {
            switch self {
            case .messageCreated(let message), .messageUpdated(let message), .messageDeleted(let message):
                message.name
            default: nil
            }
        }
    }

    var id: String
    var time: Timestamp
    var seq: Int
    var payload: Payload
}

struct SpaceState: Sendable {
    var space: Space
    var members: [Membership]
    var messages: [MessageRecord] = []
    var messageIndex: [MessageName: Int] = [:]
    var events: [StoredEvent] = []
    var threads: Set<ThreadName> = []
    var readStates: [UserName: Timestamp] = [:]
    var threadReadStates: [ThreadName: [UserName: Timestamp]] = [:]
    var notificationSettings: [UserName: SpaceNotificationSetting] = [:]
    var requestIDs: [String: MessageName] = [:]

    func isMember(_ user: UserName) -> Bool {
        members.contains { $0.member.name == user && $0.state == .joined }
    }
}

struct CustomEmojiRecord: Sendable {
    var name: CustomEmojiName
    var uid: String
    var shortcode: String
}

struct RuleEntry: Sendable {
    var rule: FailureRule
    var remaining: Int?
}

struct State: Sendable {
    var now: Timestamp
    var editsBumpLastActiveTime = false
    var idCounter: UInt64 = 0
    var userCounter = 0
    var eventSeq = 0
    var tokens: [String] = []
    var spaces: [SpaceName: SpaceState] = [:]
    var spaceOrder: [SpaceName] = []
    var emojis: [CustomEmojiRecord] = []
    var rules: [RuleEntry] = []
    var requests: [RecordedRequest] = []
    var media: [String: MediaRecord] = [:]
    var mediaByRedirectToken: [String: String] = [:]
    var uploadTokens: [String: UploadToken] = [:]
    var mediaRedirectHost: String?
    var maxUploadBytes = FakeChatServer.defaultMaxUploadBytes
    var mediaDirectory: URL?
    var mediaHostRequests: [MediaHostRequest] = []
    var emails: [UserName: String] = [:]
    var knownUsers: [UserName: User] = [:]
    var directoryEnabled = true
    var events = EventsState()

    init(start: Timestamp) {
        now = start
    }

    mutating func stamp(_ at: Timestamp?) -> Timestamp {
        if let at { return at }
        let current = now
        now = now.adding(.milliseconds(1))
        return current
    }

    mutating func newID() -> String {
        idCounter += 1
        var z = idCounter &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        var id = ""
        for _ in 0..<11 {
            id.append(alphabet[Int(z % 62)])
            z /= 62
        }
        return id
    }

    mutating func newUser(displayName: String) -> User {
        userCounter += 1
        let user = User(
            name: UserName(unchecked: "users/\(1_000_000_000_000 + userCounter)"), displayName: displayName)
        knownUsers[user.name] = user
        return user
    }

    func membership(
        of user: User, in space: SpaceName, role: Membership.Role = .member, state: Membership.State = .joined
    ) -> Membership {
        Membership(
            name: MembershipName(unchecked: "\(space.rawValue)/members/\(user.name.id(at: 0))"), member: user,
            role: role, state: state)
    }

    static let historyOffLifetime = Duration.seconds(24 * 3600)

    /// Deletes what history-off retention has expired by now, with the events that carried it.
    mutating func purgeExpired() {
        for name in spaces.keys {
            guard let space = spaces[name], space.messages.contains(where: { $0.expires.map { $0 <= now } ?? false })
            else { continue }
            let gone = Set(space.messages.filter { $0.expires.map { $0 <= now } ?? false }.map(\.message.name))
            var kept = space
            kept.messages.removeAll { gone.contains($0.message.name) }
            kept.messageIndex = Dictionary(
                uniqueKeysWithValues: kept.messages.enumerated().map { ($1.message.name, $0) })
            kept.events.removeAll { $0.payload.message.map(gone.contains) ?? false }
            spaces[name] = kept
        }
    }

    mutating func setHistory(on: Bool, in space: SpaceName) {
        guard spaces[space]?.space.historyOn != on else { return }
        spaces[space]?.space.historyOn = on
        let time = stamp(nil)
        if let updated = spaces[space]?.space { record(.spaceUpdated(updated), in: space, at: time) }
    }

    mutating func record(_ payload: StoredEvent.Payload, in space: SpaceName, at time: Timestamp) {
        eventSeq += 1
        let event = StoredEvent(id: newID(), time: time, seq: eventSeq, payload: payload)
        spaces[space]?.events.append(event)
    }

    mutating func addSpace(
        _ type: SpaceType, displayName: String, members: [User], threaded: Bool
    ) -> SpaceName {
        let time = stamp(nil)
        let name = SpaceName(unchecked: "spaces/\(newID())")
        let bots = members.filter { $0.type == .bot }
        var space = Space(
            name: name, type: type, displayName: displayName,
            isSingleUserBotDM: type == .directMessage && bots.count == 1, isThreaded: threaded,
            lastActiveTime: time, createTime: time)
        space.isExternalUserAllowed = false
        for member in members { knownUsers[member.name] = member }
        var seen = Set<UserName>()
        let memberships = members.filter { seen.insert($0.name).inserted }.map { membership(of: $0, in: name) }
        spaces[name] = SpaceState(space: space, members: memberships)
        spaceOrder.append(name)
        return name
    }

    mutating func addMember(_ user: User, to space: SpaceName, role: Membership.Role = .member, at: Timestamp?) {
        guard let state = spaces[space] else { preconditionFailure("unknown space \(space)") }
        guard !state.isMember(user.name) else { return }
        knownUsers[user.name] = user
        let time = stamp(at)
        let added = membership(of: user, in: space, role: role)
        spaces[space]?.members.append(added)
        record(.membershipCreated(added), in: space, at: time)
    }

    /// Changes an existing member's role without recording an event.
    mutating func setRole(_ role: Membership.Role, of user: UserName, in space: SpaceName) {
        guard let index = spaces[space]?.members.firstIndex(where: { $0.member.name == user }) else {
            preconditionFailure("\(user) is not in \(space)")
        }
        spaces[space]?.members[index].role = role
    }

    mutating func removeMember(_ user: User, from space: SpaceName, at: Timestamp?) {
        guard let state = spaces[space] else { preconditionFailure("unknown space \(space)") }
        guard let index = state.members.firstIndex(where: { $0.member.name == user.name }) else { return }
        let time = stamp(at)
        var removed = state.members[index]
        removed.state = .notAMember
        spaces[space]?.members.remove(at: index)
        record(.membershipDeleted(removed), in: space, at: time)
    }

    @discardableResult
    mutating func post(
        _ text: String, in space: SpaceName, from sender: User, thread: ThreadName?, formattedText: String? = nil,
        annotations: [Annotation], attachments: [Attachment], gifURLs: [URL] = [], quoted: QuotedMessage? = nil,
        cardsFallbackText: String? = nil, privateViewer: UserName? = nil, clientMessageID: String? = nil,
        at: Timestamp?
    ) -> Message {
        guard spaces[space] != nil else { preconditionFailure("unknown space \(space)") }
        let time = stamp(at)
        let threadName: ThreadName
        if let thread {
            precondition(spaces[space]?.threads.contains(thread) == true, "unknown thread \(thread)")
            threadName = thread
        } else {
            threadName = ThreadName(unchecked: "\(space.rawValue)/threads/\(newID())")
            spaces[space]?.threads.insert(threadName)
        }
        let message = Message(
            name: MessageName(unchecked: "\(space.rawValue)/messages/\(newID()).\(newID())"), sender: sender,
            createTime: time, text: text, formattedText: formattedText, annotations: annotations, thread: threadName,
            isThreadReply: thread != nil, attachments: attachments, gifURLs: gifURLs, quoted: quoted,
            cardsFallbackText: cardsFallbackText, privateViewer: privateViewer, clientMessageID: clientMessageID)
        for attachment in attachments {
            if case .uploaded(let resource) = attachment.source { media[resource.rawValue]?.spaces.insert(space) }
        }
        let position = spaces[space]?.messages.count ?? 0
        spaces[space]?.messageIndex[message.name] = position
        let expires = spaces[space]?.space.historyOn == false ? time.adding(Self.historyOffLifetime) : nil
        spaces[space]?.messages.append(MessageRecord(message: message, expires: expires))
        record(.messageCreated(message), in: space, at: time)
        bumpLastActive(space, to: time)
        return message
    }

    mutating func bumpLastActive(_ space: SpaceName, to time: Timestamp) {
        let current = spaces[space]?.space.lastActiveTime
        spaces[space]?.space.lastActiveTime = max(current ?? time, time)
    }

    func recordIndex(_ name: MessageName) -> Int {
        guard let index = spaces[name.space]?.messageIndex[name] else { preconditionFailure("unknown message \(name)") }
        return index
    }

    @discardableResult
    mutating func edit(
        _ name: MessageName, text: String, formattedText: String? = nil, annotations: [Annotation]? = nil,
        at: Timestamp?
    ) -> Message {
        let index = recordIndex(name)
        precondition(spaces[name.space]?.messages[index].message.isDeleted == false, "message is deleted")
        let time = stamp(at)
        spaces[name.space]?.messages[index].message.text = text
        spaces[name.space]?.messages[index].message.formattedText = formattedText
        if let annotations { spaces[name.space]?.messages[index].message.annotations = annotations }
        spaces[name.space]?.messages[index].message.lastUpdateTime = time
        let message = spaces[name.space]!.messages[index].message
        record(.messageUpdated(message), in: name.space, at: time)
        if editsBumpLastActiveTime { bumpLastActive(name.space, to: time) }
        return message
    }

    @discardableResult
    mutating func delete(_ name: MessageName, at: Timestamp?) -> Message {
        let index = recordIndex(name)
        precondition(spaces[name.space]?.messages[index].message.isDeleted == false, "message is deleted")
        let time = stamp(at)
        var tombstone = spaces[name.space]!.messages[index].message
        tombstone.text = ""
        tombstone.formattedText = nil
        tombstone.annotations = []
        tombstone.attachments = []
        tombstone.gifURLs = []
        tombstone.reactions = []
        tombstone.quoted = nil
        tombstone.cardsFallbackText = nil
        tombstone.deleteTime = time
        spaces[name.space]?.messages[index] = MessageRecord(message: tombstone)
        record(.messageDeleted(tombstone), in: name.space, at: time)
        if editsBumpLastActiveTime { bumpLastActive(name.space, to: time) }
        return tombstone
    }

    static func emojiKey(_ emoji: Emoji) -> String {
        switch emoji {
        case .unicode(let text): "u:\(text)"
        case .custom(let name, _): "c:\(name.rawValue)"
        }
    }

    func reactions(on name: MessageName) -> [ReactionRecord] {
        spaces[name.space]?.messageIndex[name].flatMap { spaces[name.space]?.messages[$0].reactions } ?? []
    }

    /// Returns the existing record when this user already reacted with this emoji, and records nothing.
    @discardableResult
    mutating func addReaction(
        to name: MessageName, emoji: Emoji, by user: User, at: Timestamp?
    ) -> (record: ReactionRecord, created: Bool) {
        let index = recordIndex(name)
        precondition(spaces[name.space]?.messages[index].message.isDeleted == false, "message is deleted")
        let key = Self.emojiKey(emoji)
        if let existing = reactions(on: name).first(where: {
            $0.user.name == user.name && Self.emojiKey($0.emoji) == key
        }) {
            return (existing, false)
        }
        let time = stamp(at)
        let reaction = ReactionRecord(name: "\(name.rawValue)/reactions/\(newID())", user: user, emoji: emoji)
        spaces[name.space]?.messages[index].reactions.append(reaction)
        refreshSummaries(name, index: index)
        record(.reactionCreated(reaction), in: name.space, at: time)
        if editsBumpLastActiveTime { bumpLastActive(name.space, to: time) }
        return (reaction, true)
    }

    @discardableResult
    mutating func removeReaction(_ name: ReactionName, at: Timestamp?) -> ReactionRecord {
        let message = name.message
        let index = recordIndex(message)
        guard
            let position = spaces[message.space]?.messages[index].reactions.firstIndex(where: {
                $0.name == name.rawValue
            })
        else { preconditionFailure("unknown reaction \(name)") }
        let time = stamp(at)
        let removed = spaces[message.space]!.messages[index].reactions.remove(at: position)
        refreshSummaries(message, index: index)
        record(.reactionDeleted(removed), in: message.space, at: time)
        if editsBumpLastActiveTime { bumpLastActive(message.space, to: time) }
        return removed
    }

    private mutating func refreshSummaries(_ name: MessageName, index: Int) {
        let summaries = Self.summaries(spaces[name.space]!.messages[index].reactions)
        spaces[name.space]?.messages[index].message.reactions = summaries
    }

    static func summaries(_ reactions: [ReactionRecord]) -> [ReactionSummary] {
        var order: [String] = []
        var counts: [String: (emoji: Emoji, count: Int)] = [:]
        for reaction in reactions {
            let key = emojiKey(reaction.emoji)
            if counts[key] == nil { order.append(key) }
            counts[key, default: (reaction.emoji, 0)].count += 1
        }
        return order.compactMap { key in counts[key].map { ReactionSummary(emoji: $0.emoji, count: $0.count) } }
    }

    mutating func addCustomEmoji(shortcode: String) -> CustomEmojiName {
        let id = newID()
        let name = CustomEmojiName(unchecked: "customEmojis/\(id)")
        emojis.append(CustomEmojiRecord(name: name, uid: "uid-\(id)", shortcode: shortcode))
        return name
    }
}
