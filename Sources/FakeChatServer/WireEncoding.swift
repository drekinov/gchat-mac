import ChatModel
import Foundation

typealias JSON = [String: Any]

extension State {
    func wireUser(_ user: User) -> JSON {
        var out: JSON = ["name": user.name.rawValue, "type": user.type.rawValue]
        if let displayName = user.displayName { out["displayName"] = displayName }
        if user.isAnonymous { out["isAnonymous"] = true }
        return out
    }

    func wireSpace(_ space: Space) -> JSON {
        var out: JSON = [
            "name": space.name.rawValue, "spaceType": space.type.rawValue,
            "spaceThreadingState": space.isThreaded ? "THREADED_MESSAGES" : "UNTHREADED_MESSAGES",
        ]
        if !space.displayName.isEmpty { out["displayName"] = space.displayName }
        if space.isSingleUserBotDM { out["singleUserBotDm"] = true }
        if space.isExternalUserAllowed { out["externalUserAllowed"] = true }
        if let historyOn = space.historyOn { out["spaceHistoryState"] = historyOn ? "HISTORY_ON" : "HISTORY_OFF" }
        if let time = space.lastActiveTime { out["lastActiveTime"] = time.rfc3339 }
        if let time = space.createTime { out["createTime"] = time.rfc3339 }
        return out
    }

    func wireMembership(_ membership: Membership) -> JSON {
        [
            "name": membership.name.rawValue, "state": membership.state.rawValue, "role": membership.role.rawValue,
            "member": wireUser(membership.member),
        ]
    }

    func wireCustomEmoji(_ name: CustomEmojiName, shortcode: String?) -> JSON {
        let record = emojis.first { $0.name == name }
        var out: JSON = ["name": name.rawValue, "uid": record?.uid ?? "uid-\(name.id(at: 0))"]
        if let shortcode = record?.shortcode ?? shortcode { out["emojiName"] = ":\(shortcode):" }
        return out
    }

    func wireEmoji(_ emoji: Emoji) -> JSON {
        switch emoji {
        case .unicode(let text): ["unicode": text]
        case .custom(let name, let shortcode): ["customEmoji": wireCustomEmoji(name, shortcode: shortcode)]
        }
    }

    func wireAnnotation(_ annotation: Annotation) -> JSON {
        var out: JSON = ["length": annotation.length]
        if annotation.startIndex != 0 { out["startIndex"] = annotation.startIndex }
        switch annotation.kind {
        case .userMention(let name):
            out["type"] = "USER_MENTION"
            out["userMention"] =
                [
                    "user": ["name": name.rawValue, "type": knownUsers[name]?.type.rawValue ?? "HUMAN"] as JSON,
                    "type": "MENTION",
                ] as JSON
        case .slashCommand:
            out["type"] = "SLASH_COMMAND"
            out["slashCommand"] = ["commandId": "1", "commandName": "/command", "type": "INVOKE"] as JSON
        case .richLink(let url):
            out["type"] = "RICH_LINK"
            out["richLinkMetadata"] = ["uri": url.absoluteString, "richLinkType": "RICH_LINK_TYPE_UNSPECIFIED"] as JSON
        case .customEmoji(let name, let shortcode):
            out["type"] = "CUSTOM_EMOJI"
            if let name {
                out["customEmojiMetadata"] = ["customEmoji": wireCustomEmoji(name, shortcode: shortcode)] as JSON
            } else if let shortcode {
                out["customEmojiMetadata"] = ["customEmoji": ["emojiName": ":\(shortcode):"]] as JSON
            }
        }
        return out
    }

    func wireAttachment(_ attachment: Attachment, index: Int, in message: MessageName) -> JSON {
        var out: JSON = [
            "name": "\(message.rawValue)/attachments/A\(index)", "contentName": attachment.contentName,
            "contentType": attachment.contentType,
        ]
        switch attachment.source {
        case .uploaded(let resource):
            out["source"] = "UPLOADED_CONTENT"
            out["attachmentDataRef"] = ["resourceName": resource.rawValue] as JSON
        case .drive(let fileID):
            out["source"] = "DRIVE_FILE"
            out["driveDataRef"] = ["driveFileId": fileID] as JSON
        }
        if let uri = attachment.thumbnailURI { out["thumbnailUri"] = uri.absoluteString }
        if let uri = attachment.downloadURI { out["downloadUri"] = uri.absoluteString }
        return out
    }

    func wireMessage(_ message: Message) -> JSON {
        var out: JSON = [
            "name": message.name.rawValue, "sender": wireUser(message.sender), "createTime": message.createTime.rfc3339,
        ]
        if let time = message.lastUpdateTime { out["lastUpdateTime"] = time.rfc3339 }
        if let time = message.deleteTime {
            out["deleteTime"] = time.rfc3339
            out["deletionMetadata"] = ["deletionType": "CREATOR"] as JSON
        }
        if !message.text.isEmpty { out["text"] = message.text }
        if let markup = message.formattedText { out["formattedText"] = markup }
        if let thread = message.thread { out["thread"] = ["name": thread.rawValue] as JSON }
        if message.isThreadReply { out["threadReply"] = true }
        if !message.annotations.isEmpty { out["annotations"] = message.annotations.map(wireAnnotation) }
        if !message.attachments.isEmpty {
            out["attachment"] = message.attachments.enumerated().map {
                wireAttachment($1, index: $0, in: message.name)
            }
        }
        if !message.gifURLs.isEmpty { out["attachedGifs"] = message.gifURLs.map { ["uri": $0.absoluteString] } }
        if !message.reactions.isEmpty {
            out["emojiReactionSummaries"] = message.reactions.map {
                ["emoji": wireEmoji($0.emoji), "reactionCount": $0.count] as JSON
            }
        }
        if let quoted = message.quoted {
            var metadata: JSON = ["name": quoted.name.rawValue]
            if let time = quoted.lastUpdateTime { metadata["lastUpdateTime"] = time.rfc3339 }
            out["quotedMessageMetadata"] = metadata
        }
        if let fallback = message.cardsFallbackText {
            out["fallbackText"] = fallback
            out["cardsV2"] = [["cardId": "card"] as JSON]
        }
        if let viewer = message.privateViewer { out["privateMessageViewer"] = ["name": viewer.rawValue] as JSON }
        if let id = message.clientMessageID { out["clientAssignedMessageId"] = id }
        return out
    }

    /// A deletion event's message: Google sends no sender, thread or text.
    func wireDeletedMessage(_ message: Message) -> JSON {
        var out: JSON = [
            "name": message.name.rawValue, "createTime": message.createTime.rfc3339,
            "deletionMetadata": ["deletionType": "CREATOR"] as JSON,
        ]
        if let time = message.deleteTime { out["deleteTime"] = time.rfc3339 }
        return out
    }

    func wireReaction(_ reaction: ReactionRecord) -> JSON {
        ["name": reaction.name, "user": wireUser(reaction.user), "emoji": wireEmoji(reaction.emoji)]
    }

    private func wireEntity(_ payload: StoredEvent.Payload) -> (entity: String, plural: String, object: JSON) {
        switch payload {
        case .messageCreated(let message), .messageUpdated(let message):
            ("message", "messages", wireMessage(message))
        case .messageDeleted(let message):
            ("message", "messages", wireDeletedMessage(message))
        case .reactionCreated(let reaction), .reactionDeleted(let reaction):
            ("reaction", "reactions", wireReaction(reaction))
        case .membershipCreated(let membership), .membershipDeleted(let membership):
            ("membership", "memberships", wireMembership(membership))
        case .spaceUpdated(let space):
            ("space", "spaces", wireSpace(space))
        }
    }

    /// A group of more than one event holds events of one type that share an `eventTime`, served as a batch event.
    func wireEvent(_ group: [StoredEvent], in space: SpaceName) -> JSON {
        let first = group[0]
        let (entity, plural, object) = wireEntity(first.payload)
        let action = first.payload.action
        var out: JSON = ["name": "\(space.rawValue)/spaceEvents/\(first.id)", "eventTime": first.time.rfc3339]
        if group.count > 1 {
            out["eventType"] = "google.workspace.chat.\(entity).v1.batch\(action)"
            let entries = group.map { [entity: wireEntity($0.payload).object] as JSON }
            out["\(entity)Batch\(action)EventData"] = [plural: entries] as JSON
        } else {
            out["eventType"] = first.payload.eventType
            out["\(entity)\(action)EventData"] = [entity: object] as JSON
        }
        return out
    }
}
