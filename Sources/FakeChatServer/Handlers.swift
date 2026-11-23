import ChatModel
import Foundation

extension State {
    mutating func serve(_ incoming: IncomingRequest, account: FakeAccount?) -> Outcome {
        guard let account else {
            let reply = WireError.unauthenticated.reply
            requests.append(recorded(incoming, account: nil, status: reply.status))
            return .reply(reply)
        }
        let endpoint = Endpoint.parse(method: incoming.method, path: incoming.path, host: incoming.host)
        var hasPageToken = !(incoming.value("pageToken") ?? "").isEmpty
        if case .searchMessages = endpoint {
            hasPageToken = incoming.jsonBody?["pageToken"] as? String != nil
        }
        let outcome: Outcome
        if let rule = takeRule(endpoint, account: account, hasPageToken: hasPageToken) {
            switch rule.response {
            case .http(let status, let googleStatus, let reason, let retryAfter):
                let error = WireError(
                    status: status, googleStatus: googleStatus, message: "Scripted failure: \(googleStatus)",
                    reason: reason, retryAfter: retryAfter)
                outcome = .reply(error.reply)
            case .malformedJSON:
                let real = dispatch(endpoint, incoming, account)
                let body = real.status == 200 ? real.body : Data(#"{"spaces":[{"name":"spa"#.utf8)
                var truncated = Reply.json([:])
                truncated.body = body.prefix(max(1, body.count / 2))
                outcome = .reply(truncated)
            case .networkError(let code):
                outcome = .networkError(code)
            case .commitThenNetworkError(let code):
                _ = dispatch(endpoint, incoming, account)
                outcome = .networkError(code)
            }
        } else {
            outcome = .reply(dispatch(endpoint, incoming, account))
        }
        var status: Int?
        if case .reply(let reply) = outcome { status = reply.status }
        requests.append(recorded(incoming, account: account, status: status))
        return outcome
    }

    private func recorded(_ incoming: IncomingRequest, account: FakeAccount?, status: Int?) -> RecordedRequest {
        RecordedRequest(
            method: incoming.method, path: incoming.path, query: incoming.query, account: account, status: status)
    }

    private mutating func takeRule(_ endpoint: Endpoint?, account: FakeAccount, hasPageToken: Bool) -> FailureRule? {
        for index in rules.indices {
            let rule = rules[index].rule
            guard rule.account.map({ $0.user.name == account.user.name }) ?? true else { continue }
            guard rule.route == .any || rule.route == endpoint?.route else { continue }
            guard rule.space == nil || rule.space == endpoint?.space else { continue }
            guard !rule.onlyWithPageToken || hasPageToken else { continue }
            if let remaining = rules[index].remaining {
                if remaining <= 1 { rules.remove(at: index) } else { rules[index].remaining = remaining - 1 }
            }
            return rule
        }
        return nil
    }

    private mutating func dispatch(_ endpoint: Endpoint?, _ incoming: IncomingRequest, _ account: FakeAccount) -> Reply
    {
        guard let endpoint else { return WireError.notFound("Method not found.").reply }
        do {
            return try handle(endpoint, incoming, account)
        } catch {
            return error.reply
        }
    }

    private mutating func handle(
        _ endpoint: Endpoint, _ incoming: IncomingRequest, _ account: FakeAccount
    ) throws(WireError) -> Reply {
        switch endpoint {
        case .listSpaces: try listSpaces(incoming, account)
        case .getSpace(let name): .json(wireSpace(try requireSpace(name, account).space))
        case .listMessages(let name): try listMessages(name, incoming, account)
        case .createMessage(let name): try createMessage(name, incoming, account)
        case .getMessage(let name): try getMessage(name, account)
        case .updateMessage(let name): try updateMessage(name, incoming, account)
        case .deleteMessage(let name): try deleteMessage(name, incoming, account)
        case .listSpaceEvents(let name): try listSpaceEvents(name, incoming, account)
        case .listMembers(let name): try listMembers(name, incoming, account)
        case .getSpaceReadState(let name, let user): try getSpaceReadState(name, user, account)
        case .updateSpaceReadState(let name, let user): try updateSpaceReadState(name, user, incoming, account)
        case .getThreadReadState(let space, let thread, let user): try getThreadReadState(space, thread, user, account)
        case .updateThreadReadState(let space, let thread, let user):
            try updateThreadReadState(space, thread, user, incoming, account)
        case .searchMessages: try searchMessages(incoming, account)
        case .getNotificationSetting(let name, let user): try getNotificationSetting(name, user, account)
        case .listCustomEmojis: try listCustomEmojis(incoming, account)
        case .createReaction(let name): try createReaction(name, incoming, account)
        case .deleteReaction(let name): try deleteReaction(name, account)
        case .listReactions(let name): try listReactions(name, incoming, account)
        case .uploadAttachment(let name): try uploadAttachment(name, incoming, account)
        case .downloadMedia(let resource): try downloadMedia(resource, incoming, account)
        case .setUpSpace: try setUpSpace(incoming, account)
        case .searchDirectory: try searchDirectory(incoming, account)
        }
    }

    private func requireMessage(_ name: MessageName, _ account: FakeAccount) throws(WireError) -> MessageRecord {
        let space = try requireSpace(name.space, account)
        guard let index = space.messageIndex[name], !space.messages[index].message.isDeleted else {
            throw .notFound("Message not found: \(name)")
        }
        return space.messages[index]
    }

    private func parseEmoji(_ incoming: IncomingRequest) throws(WireError) -> Emoji {
        guard let data = incoming.body, let body = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
            let emoji = body["emoji"] as? JSON
        else { throw .invalidArgument("Body needs an emoji") }
        switch (emoji["unicode"] as? String, emoji["customEmoji"] as? JSON) {
        case (let text?, nil) where !text.isEmpty:
            return .unicode(text)
        case (nil, let custom?):
            guard let raw = custom["name"] as? String, let name = CustomEmojiName(raw),
                let record = emojis.first(where: { $0.name == name })
            else { throw .invalidArgument("Unknown custom emoji") }
            return .custom(name, shortcode: record.shortcode)
        default:
            throw .invalidArgument("emoji needs exactly one of unicode and customEmoji")
        }
    }

    private mutating func createReaction(
        _ name: MessageName, _ incoming: IncomingRequest, _ account: FakeAccount
    ) throws(WireError) -> Reply {
        _ = try requireMessage(name, account)
        let emoji = try parseEmoji(incoming)
        let (record, created) = addReaction(to: name, emoji: emoji, by: account.user, at: nil)
        guard created else { throw .alreadyExists("The user already reacted with this emoji") }
        return .json(wireReaction(record))
    }

    private mutating func deleteReaction(_ name: ReactionName, _ account: FakeAccount) throws(WireError) -> Reply {
        let message = try requireMessage(name.message, account)
        // Google answers 403, not 404, for a reaction that's already gone.
        guard let reaction = message.reactions.first(where: { $0.name == name.rawValue }) else {
            throw .permissionDenied("Permission denied to delete reaction: \(name)")
        }
        guard reaction.user.name == account.user.name else {
            throw .permissionDenied("Only the author of a reaction can delete it")
        }
        removeReaction(name, at: nil)
        return .json([:])
    }

    private func listReactions(
        _ name: MessageName, _ incoming: IncomingRequest, _ account: FakeAccount
    ) throws(WireError) -> Reply {
        let message = try requireMessage(name, account)
        let paging = try PageRequest.parse(incoming, account: account.user.name, defaultSize: 25, maxSize: 200)
        let filter = try ReactionFilter.parse(incoming.value("filter"))
        let reactions = message.reactions.filter { reaction in
            filter?.matches(reaction, uid: { id in emojis.first { $0.name == id }?.uid ?? "uid-\(id.id(at: 0))" })
                ?? true
        }
        let (page, next) = paging.slice(reactions)
        var body: JSON = [:]
        if !page.isEmpty { body["reactions"] = page.map(wireReaction) }
        if let next { body["nextPageToken"] = next }
        return .json(body)
    }

    func requireSpace(_ name: SpaceName, _ account: FakeAccount) throws(WireError) -> SpaceState {
        guard let space = spaces[name] else { throw .notFound("Space not found: \(name)") }
        guard space.isMember(account.user.name) else {
            throw .permissionDenied("The caller does not have permission")
        }
        return space
    }

    private func requireOwnUser(_ segment: String, _ account: FakeAccount) throws(WireError) {
        guard segment == "me" || segment == account.user.name.id(at: 0) else {
            throw .permissionDenied("The caller does not have permission")
        }
    }

    private func listSpaces(_ incoming: IncomingRequest, _ account: FakeAccount) throws(WireError) -> Reply {
        let paging = try PageRequest.parse(incoming, account: account.user.name)
        let visible = spaceOrder.compactMap { spaces[$0] }.filter { $0.isMember(account.user.name) }
        let (page, next) = paging.slice(visible)
        var body: JSON = [:]
        if !page.isEmpty { body["spaces"] = page.map { wireSpace($0.space) } }
        if let next { body["nextPageToken"] = next }
        return .json(body)
    }

    private func listMessages(
        _ name: SpaceName, _ incoming: IncomingRequest, _ account: FakeAccount
    ) throws(WireError) -> Reply {
        let space = try requireSpace(name, account)
        let paging = try PageRequest.parse(incoming, account: account.user.name)
        let filter = try MessageFilter.parse(incoming.value("filter"))
        let descending = try Self.parseOrder(incoming.value("orderBy"))
        let showDeleted = incoming.value("showDeleted") == "true"
        var messages = space.messages.map(\.message).enumerated()
            .filter { (showDeleted || !$0.element.isDeleted) && filter.matches($0.element) }
            .sorted { ($0.element.createTime, $0.offset) < ($1.element.createTime, $1.offset) }
            .map(\.element)
        if descending { messages.reverse() }
        let (page, next) = paging.slice(messages)
        var body: JSON = [:]
        if !page.isEmpty { body["messages"] = page.map(wireMessage) }
        if let next { body["nextPageToken"] = next }
        return .json(body)
    }

    private static func parseOrder(_ text: String?) throws(WireError) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let parts = text.split(separator: " ").map { $0.lowercased() }
        guard parts.first == "createtime", parts.count <= 2 else { throw .invalidArgument("Invalid orderBy: \(text)") }
        switch parts.count == 2 ? parts[1] : "asc" {
        case "asc": return false
        case "desc": return true
        default: throw .invalidArgument("Invalid orderBy: \(text)")
        }
    }

    private func getMessage(_ name: MessageName, _ account: FakeAccount) throws(WireError) -> Reply {
        let space = try requireSpace(name.space, account)
        guard let index = space.messageIndex[name] else { throw .notFound("Message not found: \(name)") }
        return .json(wireMessage(space.messages[index].message))
    }

    /// Only the sender may edit; only `updateMask=text` is supported.
    private mutating func updateMessage(
        _ name: MessageName, _ incoming: IncomingRequest, _ account: FakeAccount
    ) throws(WireError) -> Reply {
        let record = try requireMessage(name, account)
        guard record.message.sender.name == account.user.name else {
            throw .permissionDenied("Only the sender can update this message")
        }
        guard incoming.value("updateMask") == "text" else { throw .invalidArgument("Unsupported updateMask") }
        guard let text = incoming.jsonBody?["text"] as? String else { throw .invalidArgument("Body needs text") }
        guard text.utf8.count <= 32_000 else { throw .invalidArgument("Message text exceeds 32000 bytes") }
        let (storedText, mentions) = applyMentions(text)
        return .json(wireMessage(edit(name, text: storedText, annotations: mentions, at: nil)))
    }

    /// The sender, or a space manager, may delete. A thread starter with live replies needs `force`.
    private mutating func deleteMessage(
        _ name: MessageName, _ incoming: IncomingRequest, _ account: FakeAccount
    ) throws(WireError) -> Reply {
        let record = try requireMessage(name, account)
        let space = try requireSpace(name.space, account)
        let role = space.members.first { $0.member.name == account.user.name }?.role
        guard record.message.sender.name == account.user.name || role == .manager || role == .assistantManager else {
            throw .permissionDenied("The caller does not have permission to delete this message")
        }
        let replies = space.messages.map(\.message).filter {
            !$0.isThreadReply ? false : $0.thread == record.message.thread && !$0.isDeleted && $0.name != name
        }
        if !record.message.isThreadReply, !replies.isEmpty {
            guard incoming.value("force") == "true" else {
                throw .failedPrecondition("The message has replies; set force to delete them too")
            }
            for reply in replies { delete(reply.name, at: nil) }
        }
        delete(name, at: nil)
        return .json([:])
    }

    /// Sample mode implements keyword search across the calling account’s eligible spaces.
    private func searchMessages(_ incoming: IncomingRequest, _ account: FakeAccount) throws(WireError) -> Reply {
        guard let body = incoming.jsonBody, let filter = body["filter"] as? String, !filter.isEmpty else {
            throw .invalidArgument("Search requires a filter")
        }
        var pagingRequest = incoming
        pagingRequest.query = [URLQueryItem(name: "filter", value: filter)]
        if let size = body["pageSize"] as? Int {
            pagingRequest.query.append(.init(name: "pageSize", value: String(size)))
        }
        if let token = body["pageToken"] as? String {
            pagingRequest.query.append(.init(name: "pageToken", value: token))
        }
        let paging = try PageRequest.parse(pagingRequest, account: account.user.name, defaultSize: 25, maxSize: 100)
        let words = filter.split(whereSeparator: \.isWhitespace)
        var matches: [Message] = []
        for space in spaces.values
        where space.isMember(account.user.name)
            && space.notificationSettings[account.user.name]?.isMuted != true && !space.space.isSingleUserBotDM
        {
            for record in space.messages {
                let message = record.message
                guard !message.isDeleted, message.privateViewer == nil, message.sender.type == .human,
                    words.allSatisfy({ message.text.localizedCaseInsensitiveContains(String($0)) })
                else { continue }
                matches.append(message)
            }
        }
        matches.sort { ($0.createTime, $0.name.rawValue) > ($1.createTime, $1.name.rawValue) }
        let (page, next) = paging.slice(matches)
        var result: JSON = ["results": page.map { ["message": wireMessage($0)] }]
        if let next { result["nextPageToken"] = next }
        return .json(result)
    }

    private mutating func createMessage(
        _ name: SpaceName, _ incoming: IncomingRequest, _ account: FakeAccount
    ) throws(WireError) -> Reply {
        let space = try requireSpace(name, account)
        let requestKey = incoming.value("requestId").map { "\(account.user.name.rawValue)|\($0)" }
        if let requestKey, let existing = space.requestIDs[requestKey], let index = space.messageIndex[existing] {
            return .json(wireMessage(space.messages[index].message))
        }
        guard let data = incoming.body, let body = (try? JSONSerialization.jsonObject(with: data)) as? JSON else {
            throw .invalidArgument("Request body must be a JSON object")
        }
        let text = body["text"] as? String ?? ""
        guard text.utf8.count <= 32_000 else { throw .invalidArgument("Message text exceeds 32000 bytes") }
        var attachments: [Attachment] = []
        for entry in body["attachment"] as? [JSON] ?? [] {
            guard let token = (entry["attachmentDataRef"] as? JSON)?["attachmentUploadToken"] as? String else {
                throw .invalidArgument("attachment needs attachmentDataRef.attachmentUploadToken")
            }
            guard let upload = uploadTokens[token], let record = media[upload.resource] else {
                throw .invalidArgument("Unknown attachmentUploadToken")
            }
            guard upload.space == name else {
                throw .invalidArgument("attachmentUploadToken was issued for a different space")
            }
            attachments.append(
                Attachment(
                    contentName: record.filename, contentType: record.contentType, source: .uploaded(record.resource)))
        }
        guard !text.isEmpty || !attachments.isEmpty else { throw .invalidArgument("Message has no content") }

        let option = incoming.value("messageReplyOption")
        let knownOptions = [
            "MESSAGE_REPLY_OPTION_UNSPECIFIED", "REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD", "REPLY_MESSAGE_OR_FAIL",
        ]
        if let option, !option.isEmpty, !knownOptions.contains(option) {
            throw .invalidArgument("Invalid messageReplyOption: \(option)")
        }
        let requested = ((body["thread"] as? JSON)?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var thread: ThreadName?
        if let requested {
            guard let parsed = ThreadName(requested), parsed.space == name else {
                throw .invalidArgument("Invalid thread name: \(requested)")
            }
            if space.threads.contains(parsed) {
                thread = parsed
            } else if option == "REPLY_MESSAGE_OR_FAIL" {
                throw .notFound("Thread not found: \(requested)")
            }
        } else if option == "REPLY_MESSAGE_OR_FAIL" {
            throw .invalidArgument("REPLY_MESSAGE_OR_FAIL requires thread.name")
        }

        let (storedText, mentions) = applyMentions(text)
        let message = post(
            storedText, in: name, from: account.user, thread: thread, annotations: mentions, attachments: attachments,
            clientMessageID: body["clientAssignedMessageId"] as? String, at: nil)
        if let requestKey { spaces[name]?.requestIDs[requestKey] = message.name }
        return .json(wireMessage(message))
    }

    private func listSpaceEvents(
        _ name: SpaceName, _ incoming: IncomingRequest, _ account: FakeAccount
    ) throws(WireError) -> Reply {
        let space = try requireSpace(name, account)
        let paging = try PageRequest.parse(incoming, account: account.user.name)
        let filter = try EventFilter.parse(incoming.value("filter"), now: now)
        let events = space.events.filter(filter.matches).sorted { ($0.time, $0.seq) < ($1.time, $1.seq) }

        struct GroupKey: Hashable {
            var type: String
            var time: Timestamp
        }
        var groups: [[StoredEvent]] = []
        var groupIndex: [GroupKey: Int] = [:]
        for event in events {
            let key = GroupKey(type: event.payload.eventType, time: event.time)
            if let index = groupIndex[key] {
                groups[index].append(event)
            } else {
                groupIndex[key] = groups.count
                groups.append([event])
            }
        }
        let (page, next) = paging.slice(groups)
        var body: JSON = [:]
        if !page.isEmpty { body["spaceEvents"] = page.map { wireEvent($0, in: name) } }
        if let next { body["nextPageToken"] = next }
        return .json(body)
    }

    private func listMembers(
        _ name: SpaceName, _ incoming: IncomingRequest, _ account: FakeAccount
    ) throws(WireError) -> Reply {
        let space = try requireSpace(name, account)
        let paging = try PageRequest.parse(incoming, account: account.user.name)
        let (page, next) = paging.slice(space.members)
        var body: JSON = [:]
        if !page.isEmpty { body["memberships"] = page.map(wireMembership) }
        if let next { body["nextPageToken"] = next }
        return .json(body)
    }

    private func readStateBody(_ name: String, _ time: Timestamp?) -> JSON {
        var body: JSON = ["name": name]
        if let time { body["lastReadTime"] = time.rfc3339 }
        return body
    }

    private func getSpaceReadState(
        _ name: SpaceName, _ user: String, _ account: FakeAccount
    ) throws(WireError) -> Reply {
        try requireOwnUser(user, account)
        let space = try requireSpace(name, account)
        let resource = "\(account.user.name.rawValue)/\(name.rawValue)/spaceReadState"
        return .json(readStateBody(resource, space.readStates[account.user.name]))
    }

    private mutating func updateSpaceReadState(
        _ name: SpaceName, _ user: String, _ incoming: IncomingRequest, _ account: FakeAccount
    ) throws(WireError) -> Reply {
        try requireOwnUser(user, account)
        let space = try requireSpace(name, account)
        guard incoming.value("updateMask") == "lastReadTime" else {
            throw .invalidArgument("updateMask must be lastReadTime")
        }
        guard let data = incoming.body, let body = (try? JSONSerialization.jsonObject(with: data)) as? JSON,
            let text = body["lastReadTime"] as? String, var time = Timestamp(rfc3339: text)
        else { throw .invalidArgument("Body needs a valid lastReadTime") }
        if let latest = space.messages.map(\.message.createTime).max(), time > latest { time = latest }
        spaces[name]?.readStates[account.user.name] = time
        let resource = "\(account.user.name.rawValue)/\(name.rawValue)/spaceReadState"
        return .json(readStateBody(resource, time))
    }

    private func getThreadReadState(
        _ name: SpaceName, _ thread: ThreadName, _ user: String, _ account: FakeAccount
    ) throws(WireError) -> Reply {
        try requireOwnUser(user, account)
        let space = try requireSpace(name, account)
        guard space.threads.contains(thread) else { throw .notFound("Thread not found: \(thread)") }
        let resource = "\(account.user.name.rawValue)/\(thread.rawValue)/threadReadState"
        return .json(readStateBody(resource, space.threadReadStates[thread]?[account.user.name]))
    }

    private mutating func updateThreadReadState(
        _ space: SpaceName, _ thread: ThreadName, _ user: String, _ incoming: IncomingRequest, _ account: FakeAccount
    ) throws(WireError) -> Reply {
        try requireOwnUser(user, account)
        guard try requireSpace(space, account).threads.contains(thread) else { throw .notFound("Unknown thread") }
        let name = "users/\(user)/\(thread.rawValue)/threadReadState"
        guard incoming.value("updateMask") == "lastReadTime", let body = incoming.jsonBody,
            body["name"] as? String == name, let raw = body["lastReadTime"] as? String,
            let time = Timestamp(rfc3339: raw), time.seconds >= 0
        else { throw .invalidArgument("Invalid thread read state") }
        let stored = min(time, now)
        spaces[space]?.threadReadStates[thread, default: [:]][account.user.name] = stored
        return .json(readStateBody("\(account.user.name.rawValue)/\(thread.rawValue)/threadReadState", stored))
    }

    private func getNotificationSetting(
        _ name: SpaceName, _ user: String, _ account: FakeAccount
    ) throws(WireError) -> Reply {
        try requireOwnUser(user, account)
        let space = try requireSpace(name, account)
        let setting =
            space.notificationSettings[account.user.name] ?? SpaceNotificationSetting(level: .all, isMuted: false)
        return .json([
            "name": "\(account.user.name.rawValue)/\(name.rawValue)/spaceNotificationSetting",
            "notificationSetting": setting.level.rawValue, "muteSetting": setting.isMuted ? "MUTED" : "UNMUTED",
        ])
    }

    private func listCustomEmojis(_ incoming: IncomingRequest, _ account: FakeAccount) throws(WireError) -> Reply {
        let paging = try PageRequest.parse(incoming, account: account.user.name)
        let (page, next) = paging.slice(emojis)
        var body: JSON = [:]
        if !page.isEmpty {
            body["customEmojis"] = page.map { emoji -> JSON in
                var out = wireCustomEmoji(emoji.name, shortcode: emoji.shortcode)
                out["temporaryImageUri"] = "https://fake-emoji.example/\(emoji.name.id(at: 0)).png"
                return out
            }
        }
        if let next { body["nextPageToken"] = next }
        return .json(body)
    }
}
