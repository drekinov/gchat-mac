import ChatModel
import ChatNet
import Foundation

private struct CreateReactionBody: Encodable {
    struct EmojiRef: Encodable {
        struct CustomRef: Encodable { var name: CustomEmojiName }
        var unicode: String?
        var customEmoji: CustomRef?
    }
    var emoji: EmojiRef

    init(_ emoji: Emoji) {
        switch emoji {
        case .unicode(let text): self.emoji = EmojiRef(unicode: text)
        case .custom(let name, _): self.emoji = EmojiRef(customEmoji: .init(name: name))
        }
    }
}

private struct CreateMessageBody: Encodable {
    struct ThreadRef: Encodable {
        var name: ThreadName
    }
    struct AttachmentRef: Encodable {
        struct DataRef: Encodable {
            var attachmentUploadToken: String
        }
        var attachmentDataRef: DataRef
    }

    var text: String
    var thread: ThreadRef?
    var attachment: [AttachmentRef]?
}

private struct ReadStateBody: Encodable {
    var name: String? = nil
    var lastReadTime: Timestamp
}

private struct MessageSearchBody: Encodable {
    var filter: String
    var pageSize: Int
    var pageToken: String?
}

extension GoogleChatClient {
    static let maxPageSize = 1000
    static let maxMessageBytes = 32_000
    static let maxEventWindow: Duration = .seconds(28 * 24 * 60 * 60)

    private static func invalid(_ status: String) -> ChatAPIError {
        .invalidArgument(GoogleErrorInfo(httpStatus: 0, status: status))
    }

    private static func paging(pageSize: Int? = nil, pageToken: String?) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let pageSize {
            items.append(URLQueryItem(name: "pageSize", value: String(min(max(pageSize, 1), maxPageSize))))
        }
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return items
    }

    private static func isEventType(_ type: String) -> Bool {
        !type.isEmpty
            && type.utf8.allSatisfy {
                ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z"))
                    || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
                    || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_")
            }
    }
}

extension GoogleChatClient: ChatAPI {
    public func listSpaces(pageSize: Int, pageToken: String?) async throws(ChatAPIError) -> Page<Space> {
        let page: Wire.SpacesPage = try await send(
            .get, url("/v1/spaces", query: Self.paging(pageSize: pageSize, pageToken: pageToken)))
        let raw = page.spaces ?? []
        let items = raw.compactMap { try? $0.value?.domain() }
        return Page(
            items: items, nextPageToken: Mapping.pageToken(page.nextPageToken), skipped: raw.count - items.count)
    }

    public func getSpace(_ space: SpaceName) async throws(ChatAPIError) -> Space {
        let dto: Wire.SpaceDTO = try await send(.get, url("/v1/\(space.rawValue)"))
        return try dto.domain()
    }

    public func listMessages(
        in space: SpaceName, window: CreateTimeWindow, thread: ThreadName?, order: MessageOrder, pageSize: Int,
        showDeleted: Bool, pageToken: String?
    ) async throws(ChatAPIError) -> Page<Message> {
        var clauses: [String] = []
        if let after = window.after { clauses.append("createTime > \"\(after.rfc3339)\"") }
        if let before = window.before { clauses.append("createTime < \"\(before.rfc3339)\"") }
        if let thread { clauses.append("thread.name = \(thread.rawValue)") }

        var query = Self.paging(pageSize: pageSize, pageToken: pageToken)
        if !clauses.isEmpty { query.append(URLQueryItem(name: "filter", value: clauses.joined(separator: " AND "))) }
        query.append(URLQueryItem(name: "orderBy", value: order.rawValue))
        if showDeleted { query.append(URLQueryItem(name: "showDeleted", value: "true")) }

        let page: Wire.MessagesPage = try await send(.get, url("/v1/\(space.rawValue)/messages", query: query))
        let raw = page.messages ?? []
        let items = raw.compactMap { try? $0.value?.domain() }
        return Page(
            items: items, nextPageToken: Mapping.pageToken(page.nextPageToken), skipped: raw.count - items.count)
    }

    public func getMessage(_ message: MessageName) async throws(ChatAPIError) -> Message {
        let dto: Wire.MessageDTO = try await send(.get, url("/v1/\(message.rawValue)"))
        return try dto.domain()
    }

    public func searchMessages(
        _ query: String, pageSize: Int, pageToken: String?
    ) async throws(ChatAPIError) -> Page<Message> {
        let filter = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty, filter.unicodeScalars.count <= 1000 else { throw Self.invalid("CLIENT_SEARCH_QUERY") }
        let body = MessageSearchBody(filter: filter, pageSize: min(max(pageSize, 1), 100), pageToken: pageToken)
        let response: Wire.MessageSearchPage = try await send(.post, url("/v1/spaces/-/messages:search"), body: body)
        let hits = response.results ?? []
        let messages = hits.compactMap { try? $0.value?.message.domain() }
        return Page(
            items: messages, nextPageToken: Mapping.pageToken(response.nextPageToken),
            skipped: hits.count - messages.count)
    }

    public func listSpaceEvents(
        in space: SpaceName, types: [String], start: Timestamp, end: Timestamp, pageToken: String?
    ) async throws(ChatAPIError) -> Page<TimedSpaceEvent> {
        guard !types.isEmpty, types.allSatisfy(Self.isEventType), end > start,
            end <= start.adding(Self.maxEventWindow)
        else { throw Self.invalid("CLIENT_INVALID_WINDOW") }

        let typeClauses = types.map { "eventTypes:\"\($0)\"" }.joined(separator: " OR ")
        let filter = "startTime=\"\(start.rfc3339)\" AND endTime=\"\(end.rfc3339)\" AND (\(typeClauses))"
        var query = [URLQueryItem(name: "filter", value: filter)]
        query += Self.paging(pageToken: pageToken)

        let page: Wire.SpaceEventsPage = try await send(.get, url("/v1/\(space.rawValue)/spaceEvents", query: query))
        let raw = page.spaceEvents ?? []
        let decoded = raw.map { $0.value?.domainCounting() ?? (events: [], skipped: 1) }
        return Page(
            items: decoded.flatMap(\.events), nextPageToken: Mapping.pageToken(page.nextPageToken),
            skipped: decoded.reduce(0) { $0 + $1.skipped })
    }

    public func listMemberships(in space: SpaceName, pageToken: String?) async throws(ChatAPIError) -> Page<Membership>
    {
        let page: Wire.MembershipsPage = try await send(
            .get, url("/v1/\(space.rawValue)/members", query: Self.paging(pageToken: pageToken)))
        return Page(
            items: (page.memberships ?? []).compactMap { try? $0.value?.domain() },
            nextPageToken: Mapping.pageToken(page.nextPageToken))
    }

    public func getSpaceReadState(_ space: SpaceName) async throws(ChatAPIError) -> Timestamp? {
        let dto: Wire.ReadStateDTO = try await send(.get, url("/v1/users/me/\(space.rawValue)/spaceReadState"))
        return try dto.domain()
    }

    public func updateSpaceReadState(
        _ space: SpaceName, lastReadTime: Timestamp
    ) async throws(ChatAPIError) -> Timestamp? {
        let endpoint = url(
            "/v1/users/me/\(space.rawValue)/spaceReadState",
            query: [URLQueryItem(name: "updateMask", value: "lastReadTime")])
        let dto: Wire.ReadStateDTO = try await send(.patch, endpoint, body: ReadStateBody(lastReadTime: lastReadTime))
        return try dto.domain()
    }

    public func getThreadReadState(_ thread: ThreadName) async throws(ChatAPIError) -> Timestamp? {
        let dto: Wire.ReadStateDTO = try await send(.get, url("/v1/\(Self.threadReadResource(thread))"))
        return try dto.domain()
    }

    public func updateThreadReadState(
        _ thread: ThreadName, lastReadTime: Timestamp
    ) async throws(ChatAPIError) -> Timestamp? {
        let name = Self.threadReadResource(thread)
        let endpoint = url("/v1/\(name)", query: [URLQueryItem(name: "updateMask", value: "lastReadTime")])
        let body = ReadStateBody(name: name, lastReadTime: lastReadTime)
        let dto: Wire.ReadStateDTO = try await send(.patch, endpoint, body: body)
        return try dto.domain()
    }

    private static func threadReadResource(_ thread: ThreadName) -> String {
        "users/me/\(thread.rawValue)/threadReadState"
    }

    public func getNotificationSetting(_ space: SpaceName) async throws(ChatAPIError) -> SpaceNotificationSetting {
        let dto: Wire.NotificationSettingDTO = try await send(
            .get, url("/v1/users/me/\(space.rawValue)/spaceNotificationSetting"))
        return dto.domain()
    }

    public func listCustomEmojis(pageToken: String?) async throws(ChatAPIError) -> Page<CustomEmoji> {
        let page: Wire.CustomEmojisPage = try await send(
            .get, url("/v1/customEmojis", query: Self.paging(pageToken: pageToken)))
        return Page(
            items: (page.customEmojis ?? []).compactMap { $0.value?.domain() },
            nextPageToken: Mapping.pageToken(page.nextPageToken))
    }

    public func createMessage(_ message: NewMessage) async throws(ChatAPIError) -> CreatedMessage {
        guard message.text.utf8.count <= Self.maxMessageBytes else { throw Self.invalid("CLIENT_TEXT_TOO_LONG") }

        var query = [URLQueryItem(name: "requestId", value: message.requestID.uuidString.lowercased())]
        var body = CreateMessageBody(text: message.text)
        if case .thread(let thread) = message.reply {
            query.append(URLQueryItem(name: "messageReplyOption", value: "REPLY_MESSAGE_OR_FAIL"))
            body.thread = .init(name: thread)
        }
        if !message.attachmentUploadTokens.isEmpty {
            body.attachment = message.attachmentUploadTokens.map {
                .init(attachmentDataRef: .init(attachmentUploadToken: $0))
            }
        }

        let dto: Wire.MessageDTO = try await send(
            .post, url("/v1/\(message.space.rawValue)/messages", query: query), body: body)
        guard let raw = dto.name, let name = MessageName(raw), name.space == message.space else {
            throw .decoding(path: "name")
        }
        return CreatedMessage(name: name, message: try? dto.domain())
    }

    public func createReaction(on message: MessageName, emoji: Emoji) async throws(ChatAPIError) -> Reaction {
        if case .unicode(let text) = emoji, text.isEmpty || text.unicodeScalars.count > 16 {
            throw Self.invalid("CLIENT_INVALID_EMOJI")
        }
        let dto: Wire.ReactionDTO = try await send(
            .post, url("/v1/\(message.rawValue)/reactions"), body: CreateReactionBody(emoji))
        let reaction = try dto.domain(fallbackUser: UserName(unchecked: "users/me"))
        guard reaction.name.message == message else { throw .decoding(path: "name") }
        return reaction
    }

    public func deleteReaction(_ reaction: ReactionName) async throws(ChatAPIError) {
        let _: Empty = try await send(.delete, url("/v1/\(reaction.rawValue)"))
    }

    public func listReactions(
        on message: MessageName, user: UserName?, pageToken: String?
    ) async throws(ChatAPIError) -> Page<Reaction> {
        var query = Self.paging(pageSize: 200, pageToken: pageToken)
        if let user { query.append(URLQueryItem(name: "filter", value: "user.name = \"\(user.rawValue)\"")) }
        let page: Wire.ReactionsPage = try await send(.get, url("/v1/\(message.rawValue)/reactions", query: query))
        let raw = page.reactions ?? []
        let items = raw.compactMap { try? $0.value?.domain() }
        return Page(
            items: items, nextPageToken: Mapping.pageToken(page.nextPageToken), skipped: raw.count - items.count)
    }

}
