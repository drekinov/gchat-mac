import ChatModel
import ChatNet
import Foundation

enum Mapping {
    static let unknownUser = User(name: UserName(unchecked: "users/unknown"), type: .human)

    static func timestamp(_ text: String?) -> Timestamp? {
        text.flatMap { Timestamp(rfc3339: $0) }
    }

    static func webURL(_ text: String?, httpsOnly: Bool = false) -> URL? {
        guard let text, let url = URL(string: text), url.host() != nil, let scheme = url.scheme?.lowercased() else {
            return nil
        }
        return scheme == "https" || (!httpsOnly && scheme == "http") ? url : nil
    }

    static func pageToken(_ token: String?) -> String? {
        token?.isEmpty == false ? token : nil
    }

    /// `spaces/{s}/messages/{m}/reactions/{r}` → `spaces/{s}/messages/{m}`.
    static func messageName(ofReaction name: String?) -> MessageName? {
        guard let name else { return nil }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 6, parts[4] == "reactions", !parts[5].isEmpty else { return nil }
        return MessageName(parts[0..<4].joined(separator: "/"))
    }
}

extension Wire.UserDTO {
    func domain() -> User? {
        guard let name = name.flatMap({ UserName($0) }) else { return nil }
        return User(
            name: name, type: type == "BOT" ? .bot : .human, displayName: displayName, isAnonymous: isAnonymous ?? false
        )
    }
}

extension Mapping {
    /// An https photo on a host the photo fetcher accepts, re-sized with Google's `=s<pixels>-c` suffix so only a small image
    /// is downloaded.
    static func profilePhotoURL(_ raw: String?, pixels: Int) -> URL? {
        guard let raw, raw.utf8.count < 2048, var components = URLComponents(string: raw) else { return nil }
        var path = components.path
        if let marker = path.lastIndex(of: "="), !path[marker...].contains("/") { path = String(path[..<marker]) }
        components.path = path + "=s\(pixels)-c"
        components.query = nil
        components.fragment = nil
        guard let url = components.url, SafeFetcher.passesSyntax(url, allowedHosts: SafeFetcher.profilePhotoHosts)
        else { return nil }
        return url
    }
}

extension Wire.SpaceDTO {
    func domain() throws(ChatAPIError) -> Space {
        guard let name = name.flatMap({ SpaceName($0) }) else { throw .decoding(path: "name") }
        guard let type = spaceType.flatMap({ SpaceType(rawValue: $0) }) else { throw .decoding(path: "spaceType") }
        return Space(
            name: name, type: type, displayName: displayName ?? "", isSingleUserBotDM: singleUserBotDm ?? false,
            isThreaded: spaceThreadingState == "THREADED_MESSAGES" || spaceThreadingState == "GROUPED_MESSAGES",
            lastActiveTime: Mapping.timestamp(lastActiveTime), createTime: Mapping.timestamp(createTime),
            isExternalUserAllowed: externalUserAllowed ?? false,
            historyOn: spaceHistoryState == "HISTORY_ON" ? true : spaceHistoryState == "HISTORY_OFF" ? false : nil)
    }
}

extension Wire.AnnotationDTO {
    func domain(textLength: Int) -> Annotation? {
        let start = startIndex ?? 0
        let length = length ?? 0
        let (end, overflow) = start.addingReportingOverflow(length)
        guard start >= 0, length >= 0, !overflow, end <= textLength else { return nil }
        let kind: Annotation.Kind
        switch type {
        case "USER_MENTION":
            guard let user = userMention?.user?.name.flatMap({ UserName($0) }) else { return nil }
            kind = .userMention(user)
        case "RICH_LINK":
            guard let url = Mapping.webURL(richLinkMetadata?.uri) else { return nil }
            kind = .richLink(url)
        case "CUSTOM_EMOJI":
            let emoji = customEmojiMetadata?.customEmoji
            let name = emoji?.name.flatMap { CustomEmojiName($0) }
            guard name != nil || emoji?.emojiName != nil else { return nil }
            kind = .customEmoji(name, shortcode: emoji?.emojiName)
        case "SLASH_COMMAND":
            kind = .slashCommand
        default:
            return nil
        }
        return Annotation(kind: kind, startIndex: start, length: length)
    }
}

extension Wire.AttachmentDTO {
    func domain() -> Attachment? {
        let source: Attachment.Source
        if let media = attachmentDataRef?.resourceName.flatMap({ MediaResourceName($0) }) {
            source = .uploaded(media)
        } else if let fileID = driveDataRef?.driveFileId, !fileID.isEmpty {
            source = .drive(fileID: fileID)
        } else {
            return nil
        }
        return Attachment(
            contentName: contentName ?? "", contentType: contentType ?? "", source: source,
            thumbnailURI: Mapping.webURL(thumbnailUri), downloadURI: Mapping.webURL(downloadUri))
    }
}

extension Wire.EmojiDTO {
    func domain() -> Emoji? {
        if let unicode, !unicode.isEmpty { return .unicode(unicode) }
        if let name = customEmoji?.name.flatMap({ CustomEmojiName($0) }) {
            return .custom(name, shortcode: customEmoji?.emojiName)
        }
        return nil
    }
}

extension Wire.ReactionDTO {
    /// `fallbackUser` covers create responses, where `user` is output-only and may be omitted.
    func domain(fallbackUser: UserName? = nil) throws(ChatAPIError) -> Reaction {
        guard let name = name.flatMap({ ReactionName($0) }) else { throw .decoding(path: "name") }
        guard let user = user?.name.flatMap({ UserName($0) }) ?? fallbackUser else {
            throw .decoding(path: "user.name")
        }
        guard let emoji = emoji?.domain() else { throw .decoding(path: "emoji") }
        let displayName = self.user?.displayName.flatMap { $0.isEmpty ? nil : $0 }
        return Reaction(name: name, user: user, emoji: emoji, userDisplayName: displayName)
    }
}

extension Wire.ReactionSummaryDTO {
    func domain() -> ReactionSummary? {
        guard let emoji = emoji?.domain() else { return nil }
        return ReactionSummary(emoji: emoji, count: max(0, reactionCount ?? 0))
    }
}

extension Wire.MessageDTO {
    func domain(deletedAt: Timestamp? = nil) throws(ChatAPIError) -> Message {
        guard let name = name.flatMap({ MessageName($0) }) else { throw .decoding(path: "name") }
        guard let createTime = Mapping.timestamp(createTime) else { throw .decoding(path: "createTime") }
        let text = text ?? ""
        let textLength = text.utf16.count
        let hasCards = cardsV2?.isEmpty == false
        let quoted = quotedMessageMetadata.flatMap { metadata -> QuotedMessage? in
            guard let quotedName = metadata.name.flatMap({ MessageName($0) }) else { return nil }
            return QuotedMessage(
                name: quotedName, lastUpdateTime: Mapping.timestamp(metadata.lastUpdateTime),
                snapshotSender: metadata.quotedMessageSnapshot?.sender.flatMap { UserName($0) },
                snapshotText: metadata.quotedMessageSnapshot?.text)
        }
        let deleted = Mapping.timestamp(deleteTime) ?? deletedAt
        return Message(
            name: name, sender: sender?.domain() ?? Mapping.unknownUser, createTime: createTime,
            lastUpdateTime: Mapping.timestamp(lastUpdateTime), deleteTime: deleted,
            text: text, formattedText: deleted == nil ? formattedText : nil,
            annotations: (annotations ?? []).compactMap { $0.value?.domain(textLength: textLength) },
            thread: thread?.name.flatMap { ThreadName($0) }, isThreadReply: threadReply ?? false,
            attachments: (attachment ?? []).compactMap { $0.value?.domain() },
            gifURLs: (attachedGifs ?? []).compactMap { Mapping.webURL($0.value?.uri, httpsOnly: true) },
            reactions: (emojiReactionSummaries ?? []).compactMap { $0.value?.domain() }, quoted: quoted,
            cardsFallbackText: hasCards ? fallbackText : nil, cards: domainCards(),
            privateViewer: privateMessageViewer?.domain()?.name,
            clientMessageID: clientAssignedMessageId)
    }
}

extension Wire.MembershipDTO {
    func domain() throws(ChatAPIError) -> Membership {
        guard let name = name.flatMap({ MembershipName($0) }) else { throw .decoding(path: "name") }
        guard let member = member?.domain() else { throw .decoding(path: "member.name") }
        return Membership(
            name: name, member: member, role: role.flatMap { Membership.Role(rawValue: $0) } ?? .unspecified,
            state: state.flatMap { Membership.State(rawValue: $0) } ?? .unspecified)
    }
}

extension Wire.CustomEmojiDTO {
    func domain() -> CustomEmoji? {
        guard let name = name.flatMap({ CustomEmojiName($0) }), let emojiName, !emojiName.isEmpty else { return nil }
        return CustomEmoji(
            name: name, shortcode: emojiName, temporaryImageURL: Mapping.webURL(temporaryImageUri, httpsOnly: true))
    }
}

extension Wire.ReadStateDTO {
    func domain() throws(ChatAPIError) -> Timestamp? {
        guard let lastReadTime else { return nil }
        guard let time = Timestamp(rfc3339: lastReadTime) else { throw .decoding(path: "lastReadTime") }
        return time
    }
}

extension Wire.NotificationSettingDTO {
    func domain() -> SpaceNotificationSetting {
        SpaceNotificationSetting(
            level: notificationSetting.flatMap { NotificationLevel(rawValue: $0) } ?? .all,
            isMuted: muteSetting == "MUTED")
    }
}

extension Wire.SpaceEventDTO {
    func domain() -> [TimedSpaceEvent] { domainCounting().events }

    /// `skipped` counts required payloads that were present but malformed, so the caller can keep its checkpoint.
    func domainCounting() -> (events: [TimedSpaceEvent], skipped: Int) {
        guard let time = Mapping.timestamp(eventTime) else { return ([], 1) }
        var events: [SpaceEvent] = []
        var skipped = 0

        func messages(
            _ single: MessageData?, _ batch: MessageBatch?, deleted: Bool = false,
            wrap: (Message) -> SpaceEvent
        ) {
            var wrappers: [MessageData] = []
            if let single { wrappers.append(single) }
            let batchItems = batch?.messages ?? []
            skipped += batchItems.filter { $0.value == nil }.count
            wrappers += batchItems.compactMap(\.value)
            for wrapper in wrappers {
                if let message = try? wrapper.message?.value?.domain(deletedAt: deleted ? time : nil) {
                    events.append(wrap(message))
                } else {
                    skipped += 1
                }
            }
        }

        messages(messageCreatedEventData, messageBatchCreatedEventData) { .messageCreated($0) }
        messages(messageUpdatedEventData, messageBatchUpdatedEventData) { .messageUpdated($0) }
        messages(messageDeletedEventData, messageBatchDeletedEventData, deleted: true) { .messageDeleted($0) }

        var reactionNames: [MessageName] = []
        var reactionWrappers: [ReactionData] = []
        for (single, batch) in [
            (reactionCreatedEventData, reactionBatchCreatedEventData),
            (reactionDeletedEventData, reactionBatchDeletedEventData),
        ] {
            if let single { reactionWrappers.append(single) }
            reactionWrappers += (batch?.reactions ?? []).compactMap(\.value)
        }
        for wrapper in reactionWrappers {
            guard let name = Mapping.messageName(ofReaction: wrapper.reaction?.value?.name) else {
                skipped += 1
                continue
            }
            if !reactionNames.contains(name) { reactionNames.append(name) }
        }
        events += reactionNames.map { .reactionsChanged($0) }

        let membershipBatches = [
            membershipBatchCreatedEventData, membershipBatchUpdatedEventData, membershipBatchDeletedEventData,
        ]
        let membershipSingles = [membershipCreatedEventData, membershipUpdatedEventData, membershipDeletedEventData]
        let membershipCount =
            membershipSingles.compactMap { $0 }.count
            + membershipBatches.reduce(0) { $0 + ($1?.memberships ?? []).compactMap(\.value).count }
        events += Array(repeating: .membershipsChanged, count: membershipCount)

        var spaceWrappers: [SpaceData] = []
        if let spaceUpdatedEventData { spaceWrappers.append(spaceUpdatedEventData) }
        spaceWrappers += (spaceBatchUpdatedEventData?.spaces ?? []).compactMap(\.value)
        for wrapper in spaceWrappers {
            if let space = try? wrapper.space?.value?.domain() { events.append(.spaceUpdated(space)) }
        }

        return (events.map { TimedSpaceEvent(time: time, event: $0) }, skipped)
    }
}
