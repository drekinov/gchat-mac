import ChatModel
import ChatNet
import Foundation
import Synchronization

/// An in-process fake of the Chat REST API. Requests reach it through `FakeChatURLProtocol`, which finds the
/// server from the bearer token.
public final class FakeChatServer: Sendable {
    let state: Mutex<State>

    public static let defaultMaxUploadBytes = 200 * 1024 * 1024

    public init(start: Timestamp = Timestamp(rfc3339: "2026-01-01T00:00:00Z")!) {
        state = Mutex(State(start: start))
        ServerList.add(self)
    }

    deinit {
        TokenRegistry.remove(state.withLock { $0.tokens })
        if let directory = state.withLock({ $0.mediaDirectory }) { try? FileManager.default.removeItem(at: directory) }
    }

    public static var protocolClass: AnyClass { FakeChatURLProtocol.self }

    public func makeTransport() -> AuthTransport {
        AuthTransport(
            allowedHosts: [
                "chat.googleapis.com", Endpoint.directoryHost, Endpoint.workspaceEventsHost, Endpoint.pubSubHost,
            ], protocolClasses: [Self.protocolClass])
    }

    // MARK: Accounts

    /// The default email is derived from the display name, e.g. `alice.smith@fake.example`.
    public func addAccount(displayName: String, email: String? = nil) -> FakeAccount {
        let account = state.withLock { state in
            let account = FakeAccount(user: state.newUser(displayName: displayName), token: UUID().uuidString)
            state.tokens.append(account.token)
            if let email { state.emails[account.user.name] = email }
            return account
        }
        TokenRegistry.register(account, server: self)
        return account
    }

    /// Returns the account with a new token. The old token answers 401 from then on.
    public func revokeToken(_ account: FakeAccount) -> FakeAccount {
        let renewed = state.withLock { state in
            let renewed = FakeAccount(user: account.user, token: UUID().uuidString)
            state.tokens.append(renewed.token)
            return renewed
        }
        TokenRegistry.revoke(account.token)
        TokenRegistry.register(renewed, server: self)
        return renewed
    }

    // MARK: Clock

    public var now: Timestamp { state.withLock { $0.now } }

    public func advance(_ duration: Duration) {
        state.withLock { $0.now = $0.now.adding(duration) }
    }

    /// When false, edits, deletes and reactions leave `Space.lastActiveTime` alone.
    public var editsBumpLastActiveTime: Bool {
        get { state.withLock { $0.editsBumpLastActiveTime } }
        set { state.withLock { $0.editsBumpLastActiveTime = newValue } }
    }

    // MARK: Seeding

    @discardableResult
    public func addSpace(
        _ type: SpaceType, displayName: String = "", members: [FakeAccount], bots: [User] = [], users: [User] = [],
        threaded: Bool = true
    ) -> SpaceName {
        state.withLock {
            $0.addSpace(
                type, displayName: displayName, members: members.map(\.user) + bots + users, threaded: threaded)
        }
    }

    /// Sets `spaceHistoryState`: off means Google Chat deletes the space's messages after about 24 hours.
    public func setHistory(on: Bool, in space: SpaceName) {
        state.withLock { $0.spaces[space]?.space.historyOn = on }
    }

    public func addMember(_ account: FakeAccount, to space: SpaceName, at: Timestamp? = nil) {
        state.withLock { $0.addMember(account.user, to: space, at: at) }
    }

    public func addMember(_ user: User, to space: SpaceName, role: Membership.Role = .member, at: Timestamp? = nil) {
        state.withLock { $0.addMember(user, to: space, role: role, at: at) }
    }

    public func setRole(_ role: Membership.Role, of account: FakeAccount, in space: SpaceName) {
        state.withLock { $0.setRole(role, of: account.user.name, in: space) }
    }

    public func removeMember(_ account: FakeAccount, from space: SpaceName, at: Timestamp? = nil) {
        state.withLock { $0.removeMember(account.user, from: space, at: at) }
    }

    public func removeMember(_ user: User, from space: SpaceName, at: Timestamp? = nil) {
        state.withLock { $0.removeMember(user, from: space, at: at) }
    }

    @discardableResult
    public func post(
        _ text: String, in space: SpaceName, from sender: FakeSender, thread: ThreadName? = nil,
        annotations: [Annotation] = [], attachments: [Attachment] = [], at: Timestamp? = nil, gifURLs: [URL] = [],
        quoted: QuotedMessage? = nil, cardsFallbackText: String? = nil, privateViewer: UserName? = nil
    ) -> Message {
        state.withLock {
            $0.post(
                text, in: space, from: sender.user, thread: thread, annotations: annotations,
                attachments: attachments, gifURLs: gifURLs, quoted: quoted, cardsFallbackText: cardsFallbackText,
                privateViewer: privateViewer, at: at)
        }
    }

    @discardableResult
    public func edit(_ message: MessageName, text: String, at: Timestamp? = nil) -> Message {
        state.withLock { $0.edit(message, text: text, at: at) }
    }

    @discardableResult
    public func delete(_ message: MessageName, at: Timestamp? = nil) -> Message {
        state.withLock { $0.delete(message, at: at) }
    }

    /// A repeat of the same user and emoji changes nothing and returns the existing reaction.
    @discardableResult
    public func react(_ message: MessageName, emoji: Emoji, by sender: FakeSender, at: Timestamp? = nil) -> ReactionName
    {
        state.withLock {
            ReactionName(unchecked: $0.addReaction(to: message, emoji: emoji, by: sender.user, at: at).record.name)
        }
    }

    public func removeReaction(_ reaction: ReactionName, at: Timestamp? = nil) {
        state.withLock { _ = $0.removeReaction(reaction, at: at) }
    }

    public func setReadState(_ account: FakeAccount, space: SpaceName, lastReadTime: Timestamp?) {
        state.withLock { $0.spaces[space]?.readStates[account.user.name] = lastReadTime }
    }

    public func threadReadState(_ account: FakeAccount, thread: ThreadName) -> Timestamp? {
        state.withLock { $0.spaces[thread.space]?.threadReadStates[thread]?[account.user.name] }
    }

    public func setThreadReadState(_ account: FakeAccount, thread: ThreadName, lastReadTime: Timestamp?) {
        state.withLock {
            $0.spaces[thread.space]?.threadReadStates[thread, default: [:]][account.user.name] = lastReadTime
        }
    }

    public func setNotificationSetting(_ account: FakeAccount, space: SpaceName, _ setting: SpaceNotificationSetting) {
        state.withLock { $0.spaces[space]?.notificationSettings[account.user.name] = setting }
    }

    @discardableResult
    public func addCustomEmoji(shortcode: String) -> CustomEmojiName {
        state.withLock { $0.addCustomEmoji(shortcode: shortcode) }
    }

    // MARK: People

    /// Adds a user who can be found in the directory and messaged with `spaces:setup`, without joining any space.
    public func addDirectoryPerson(_ user: User, email: String) {
        state.withLock {
            $0.knownUsers[user.name] = user
            $0.emails[user.name] = email
        }
    }

    public func setEmail(_ email: String, for user: User) {
        state.withLock { $0.emails[user.name] = email }
    }

    public func email(of user: User) -> String {
        state.withLock { $0.email(for: user) }
    }

    /// When false, `people:searchDirectoryPeople` answers 403.
    public var directoryEnabled: Bool {
        get { state.withLock { $0.directoryEnabled } }
        set { state.withLock { $0.directoryEnabled = newValue } }
    }

    // MARK: Media

    /// Uploads are rejected above this size. Defaults to `defaultMaxUploadBytes`.
    public var maxUploadBytes: Int {
        get { state.withLock { $0.maxUploadBytes } }
        set { state.withLock { $0.maxUploadBytes = newValue } }
    }

    /// When set, downloads answer 302 to `https://<host>/<id>`, served without auth by `FakeMediaHost`.
    public var mediaRedirectHost: String? {
        get { state.withLock { $0.mediaRedirectHost } }
        set { state.withLock { $0.mediaRedirectHost = newValue?.lowercased() } }
    }

    /// Stored without a space: nobody can download it until a message attaches it (see `postMedia`).
    public func addMedia(_ data: Data, contentType: String, filename: String) -> MediaResourceName {
        state.withLock { $0.addMedia(data, contentType: contentType, filename: filename, space: nil) }
    }

    @discardableResult
    public func postMedia(
        _ media: [MediaResourceName], text: String = "", in space: SpaceName, from sender: FakeSender,
        thread: ThreadName? = nil, at: Timestamp? = nil
    ) -> Message {
        state.withLock { state in
            let attachments = media.map { resource -> Attachment in
                guard let record = state.media[resource.rawValue] else {
                    preconditionFailure("unknown media \(resource)")
                }
                return Attachment(
                    contentName: record.filename, contentType: record.contentType, source: .uploaded(resource))
            }
            return state.post(
                text, in: space, from: sender.user, thread: thread, annotations: [], attachments: attachments, at: at)
        }
    }

    public func mediaBytes(_ resource: MediaResourceName) -> Data? {
        state.withLock { state in state.media[resource.rawValue].map { $0.bytes(0..<$0.size) } }
    }

    public var mediaHostRequests: [MediaHostRequest] { state.withLock { $0.mediaHostRequests } }

    // MARK: Failures

    public func fail(_ rule: FailureRule) {
        if let times = rule.times, times <= 0 { return }
        state.withLock { $0.rules.append(RuleEntry(rule: rule, remaining: rule.times)) }
    }

    public func clearFailures() {
        state.withLock { $0.rules.removeAll() }
    }

    // MARK: Introspection

    public var requests: [RecordedRequest] { state.withLock { $0.requests } }

    public func messages(in space: SpaceName) -> [Message] {
        state.withLock { $0.spaces[space]?.messages.map(\.message) ?? [] }
    }

    public func message(_ name: MessageName) -> Message? {
        state.withLock { state in
            state.spaces[name.space]?.messageIndex[name].flatMap { state.spaces[name.space]?.messages[$0].message }
        }
    }

    public func space(_ name: SpaceName) -> Space? {
        state.withLock { $0.spaces[name]?.space }
    }

    // MARK: Serving

    static func serveMediaHost(token: String, _ incoming: IncomingRequest) -> Reply? {
        for server in ServerList.live {
            let reply = server.state.withLock { state -> Reply? in
                guard state.mediaByRedirectToken[token] != nil else { return nil }
                return state.serveMediaHost(token: token, incoming)
            }
            if let reply { return reply }
        }
        return Reply(status: 404, headers: ["Content-Type": "text/plain"], body: Data("Not found".utf8))
    }

    static func serve(_ incoming: IncomingRequest) -> Outcome {
        guard let token = incoming.bearerToken, let entry = TokenRegistry.lookup(token), let server = entry.server
        else {
            return .reply(WireError.unauthenticated.reply)
        }
        return server.state.withLock { $0.serve(incoming, account: entry.revoked ? nil : entry.account) }
    }
}
