import ChatModel
import Foundation

public protocol TokenProvider: Sendable {
    /// A valid access token, refreshing if needed. Throws `ChatAPIError.noCredentials` when none can be produced.
    func accessToken() async throws(ChatAPIError) -> String
    /// Marks `token` as rejected so the next `accessToken()` refreshes.
    func invalidate(_ token: String) async
}

public enum MessageOrder: String, Sendable {
    case ascending = "createTime ASC"
    case descending = "createTime DESC"
}

/// Half-open on neither side: `createTime > after AND createTime < before`, matching the API filter.
public struct CreateTimeWindow: Sendable, Equatable {
    public var after: Timestamp?
    public var before: Timestamp?

    public init(after: Timestamp? = nil, before: Timestamp? = nil) {
        self.after = after
        self.before = before
    }
}

public enum ReplyTarget: Sendable, Equatable {
    case newThread
    /// Fails with `notFound`/`failedPrecondition` if the thread is gone; never falls back to a new thread.
    case thread(ThreadName)
}

public struct NewMessage: Sendable, Equatable {
    public var space: SpaceName
    public var text: String
    public var reply: ReplyTarget
    /// Generated once per outbox item and reused on every retry.
    public var requestID: UUID
    public var attachmentUploadTokens: [String]

    public init(
        space: SpaceName, text: String, reply: ReplyTarget = .newThread, requestID: UUID,
        attachmentUploadTokens: [String] = []
    ) {
        self.space = space
        self.text = text
        self.reply = reply
        self.requestID = requestID
        self.attachmentUploadTokens = attachmentUploadTokens
    }
}

/// A repeated `requestId` can return an incomplete message, so only the name is guaranteed.
public struct CreatedMessage: Hashable, Sendable {
    public var name: MessageName
    public var message: Message?

    public init(name: MessageName, message: Message?) {
        self.name = name
        self.message = message
    }
}

/// A message fetched for editing, with Google's markup (`formattedText`), which can hold formatting `text` lacks.
public struct EditableMessage: Hashable, Sendable {
    public var message: Message
    public var formattedText: String?

    public init(message: Message, formattedText: String?) {
        self.message = message
        self.formattedText = formattedText
    }
}

public struct CustomEmoji: Hashable, Sendable {
    public var name: CustomEmojiName
    public var shortcode: String
    /// Short-lived, token-less image URL; fetched only through the credential-free fetcher.
    public var temporaryImageURL: URL?

    public init(name: CustomEmojiName, shortcode: String, temporaryImageURL: URL?) {
        self.name = name
        self.shortcode = shortcode
        self.temporaryImageURL = temporaryImageURL
    }
}

public struct Reaction: Hashable, Sendable {
    public var name: ReactionName
    public var user: UserName
    public var emoji: Emoji
    /// The reacting user's name, when Google includes it.
    public var userDisplayName: String?

    public init(name: ReactionName, user: UserName, emoji: Emoji, userDisplayName: String? = nil) {
        self.name = name
        self.user = user
        self.emoji = emoji
        self.userDisplayName = userDisplayName
    }
}

public enum DirectMessageMember: Hashable, Sendable {
    case user(UserName)
    /// Google accepts an email as an alias for `users/{id}` when creating memberships.
    case email(String)

    /// The membership `member.name`, or `nil` for an unusable email.
    public var memberName: String? {
        switch self {
        case .user(let user): return user.rawValue
        case .email(let email):
            let parts = email.split(separator: "@", omittingEmptySubsequences: false)
            let forbidden = Set("\"<>()[],;:\\/?#%".unicodeScalars)
            guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."),
                email.utf8.count <= 254,
                email.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && !forbidden.contains($0) })
            else { return nil }
            return "users/\(email.lowercased())"
        }
    }
}

public struct DirectoryPerson: Hashable, Sendable {
    /// The ID in `people/{id}` is the same as the Chat user ID.
    public var user: UserName
    public var displayName: String
    public var email: String?

    public init(user: UserName, displayName: String, email: String?) {
        self.user = user
        self.displayName = displayName
        self.email = email
    }
}

/// Workspace directory search through the People API (`directory.readonly`); admins can turn it off.
public protocol PeopleDirectoryAPI: Sendable {
    func searchDirectory(_ query: String, pageToken: String?) async throws(ChatAPIError) -> Page<DirectoryPerson>
    /// Profile photos (People API `batchGet`, at most `profilePhotoBatch` users); people without one are absent.
    func profilePhotos(for users: [UserName]) async throws(ChatAPIError) -> [UserName: URL]
}

public let profilePhotoBatch = 50

extension PeopleDirectoryAPI {
    public func profilePhotos(for users: [UserName]) async throws(ChatAPIError) -> [UserName: URL] { [:] }
}

/// The Chat REST API surface used by Thimble (user auth). One instance per account.
public protocol ChatAPI: Sendable {
    func listSpaces(pageSize: Int, pageToken: String?) async throws(ChatAPIError) -> Page<Space>
    func getSpace(_ space: SpaceName) async throws(ChatAPIError) -> Space

    func listMessages(
        in space: SpaceName, window: CreateTimeWindow, thread: ThreadName?, order: MessageOrder, pageSize: Int,
        showDeleted: Bool, pageToken: String?
    ) async throws(ChatAPIError) -> Page<Message>
    func getMessage(_ message: MessageName) async throws(ChatAPIError) -> Message
    func getEditableMessage(_ message: MessageName) async throws(ChatAPIError) -> EditableMessage
    func searchMessages(_ query: String, pageSize: Int, pageToken: String?) async throws(ChatAPIError) -> Page<Message>

    /// `start`/`end` must be at most 28 days apart. Batch event payloads are flattened, oldest first.
    func listSpaceEvents(
        in space: SpaceName, types: [String], start: Timestamp, end: Timestamp, pageToken: String?
    ) async throws(ChatAPIError) -> Page<TimedSpaceEvent>

    func listMemberships(in space: SpaceName, pageToken: String?) async throws(ChatAPIError) -> Page<Membership>

    func getSpaceReadState(_ space: SpaceName) async throws(ChatAPIError) -> Timestamp?
    /// Returns the stored time; the server coerces values after the latest message.
    func updateSpaceReadState(_ space: SpaceName, lastReadTime: Timestamp) async throws(ChatAPIError) -> Timestamp?
    func getThreadReadState(_ thread: ThreadName) async throws(ChatAPIError) -> Timestamp?
    func updateThreadReadState(_ thread: ThreadName, lastReadTime: Timestamp) async throws(ChatAPIError) -> Timestamp?

    func getNotificationSetting(_ space: SpaceName) async throws(ChatAPIError) -> SpaceNotificationSetting
    func listCustomEmojis(pageToken: String?) async throws(ChatAPIError) -> Page<CustomEmoji>

    func createMessage(_ message: NewMessage) async throws(ChatAPIError) -> CreatedMessage
    /// Replaces the text of one of the user's own messages.
    func updateMessageText(_ message: MessageName, text: String) async throws(ChatAPIError) -> Message
    /// `force` also deletes the thread's replies; without it a thread starter with replies fails
    /// `failedPrecondition`.
    func deleteMessage(_ message: MessageName, force: Bool) async throws(ChatAPIError)

    /// Returns the existing DM with `member` if there is one, otherwise creates it (`spaces.setup`).
    func setUpDirectMessage(with member: DirectMessageMember) async throws(ChatAPIError) -> Space

    /// Adding an emoji the user already reacted with fails with `conflict`, which callers treat as success.
    func createReaction(on message: MessageName, emoji: Emoji) async throws(ChatAPIError) -> Reaction
    /// Deleting a reaction that's already gone fails with `permissionDenied` (Google's answer) or `notFound`.
    func deleteReaction(_ reaction: ReactionName) async throws(ChatAPIError)
    /// `user` filters to one user's reactions (`user.name = "users/…"`).
    func listReactions(
        on message: MessageName, user: UserName?, pageToken: String?
    ) async throws(ChatAPIError) -> Page<Reaction>
}
