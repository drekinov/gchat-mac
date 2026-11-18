import Foundation

/// Decodes to `nil` instead of throwing, so one malformed list element doesn't fail the page.
struct Lossy<Value: Decodable & Sendable>: Decodable, Sendable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Accepts any JSON value without keeping it.
struct Ignored: Decodable, Sendable {
    init(from decoder: any Decoder) throws {}
}

enum Wire {
    struct SpaceDTO: Decodable, Sendable {
        var name: String?
        var spaceType: String?
        var displayName: String?
        var singleUserBotDm: Bool?
        var spaceThreadingState: String?
        var lastActiveTime: String?
        var createTime: String?
        var externalUserAllowed: Bool?
        var spaceHistoryState: String?
    }

    struct UserDTO: Decodable, Sendable {
        var name: String?
        var displayName: String?
        var type: String?
        var isAnonymous: Bool?
    }

    struct ThreadDTO: Decodable, Sendable {
        var name: String?
    }

    struct MessageDTO: Decodable, Sendable {
        struct Deletion: Decodable, Sendable {
            var deletionType: String?
        }
        struct QuotedMetadata: Decodable, Sendable {
            struct Snapshot: Decodable, Sendable {
                var sender: String?
                var text: String?
            }
            var name: String?
            var lastUpdateTime: String?
            var quotedMessageSnapshot: Snapshot?
        }
        struct Gif: Decodable, Sendable {
            var uri: String?
        }

        var name: String?
        var sender: UserDTO?
        var createTime: String?
        var lastUpdateTime: String?
        var deleteTime: String?
        var deletionMetadata: Deletion?
        var text: String?
        var thread: ThreadDTO?
        var threadReply: Bool?
        var fallbackText: String?
        var cards: [Lossy<CardDTO>]?
        var cardsV2: [Lossy<CardV2DTO>]?
        var privateMessageViewer: UserDTO?
        var clientAssignedMessageId: String?
        var quotedMessageMetadata: QuotedMetadata?
        var annotations: [Lossy<AnnotationDTO>]?
        var attachment: [Lossy<AttachmentDTO>]?
        var attachedGifs: [Lossy<Gif>]?
        var emojiReactionSummaries: [Lossy<ReactionSummaryDTO>]?
    }

    struct CustomEmojiDTO: Decodable, Sendable {
        var name: String?
        var uid: String?
        var emojiName: String?
        var temporaryImageUri: String?
    }

    struct AnnotationDTO: Decodable, Sendable {
        struct UserMention: Decodable, Sendable {
            var user: UserDTO?
            var type: String?
        }
        struct RichLink: Decodable, Sendable {
            var uri: String?
            var richLinkType: String?
        }
        struct CustomEmojiMetadata: Decodable, Sendable {
            var customEmoji: CustomEmojiDTO?
        }

        var type: String?
        var startIndex: Int?
        var length: Int?
        var userMention: UserMention?
        var richLinkMetadata: RichLink?
        var customEmojiMetadata: CustomEmojiMetadata?
    }

    struct AttachmentDTO: Decodable, Sendable {
        struct DataRef: Decodable, Sendable {
            var resourceName: String?
            var attachmentUploadToken: String?
        }
        struct DriveRef: Decodable, Sendable {
            var driveFileId: String?
        }

        var name: String?
        var contentName: String?
        var contentType: String?
        var thumbnailUri: String?
        var downloadUri: String?
        var source: String?
        var attachmentDataRef: DataRef?
        var driveDataRef: DriveRef?
    }

    struct EmojiDTO: Decodable, Sendable {
        var unicode: String?
        var customEmoji: CustomEmojiDTO?
    }

    struct ReactionSummaryDTO: Decodable, Sendable {
        var emoji: EmojiDTO?
        var reactionCount: Int?
    }

    struct ReactionDTO: Decodable, Sendable {
        var name: String?
        var user: UserDTO?
        var emoji: EmojiDTO?
    }

    struct ReactionsPage: Decodable, Sendable {
        var reactions: [Lossy<ReactionDTO>]?
        var nextPageToken: String?
    }

    struct MembershipDTO: Decodable, Sendable {
        var name: String?
        var state: String?
        var role: String?
        var member: UserDTO?
    }

    struct ReadStateDTO: Decodable, Sendable {
        var name: String?
        var lastReadTime: String?
    }

    struct NotificationSettingDTO: Decodable, Sendable {
        var name: String?
        var notificationSetting: String?
        var muteSetting: String?
    }

    struct SpaceEventDTO: Decodable, Sendable {
        struct MessageData: Decodable, Sendable {
            var message: Lossy<MessageDTO>?
        }
        struct MessageBatch: Decodable, Sendable {
            var messages: [Lossy<MessageData>]?
        }
        struct ReactionData: Decodable, Sendable {
            var reaction: Lossy<ReactionDTO>?
        }
        struct ReactionBatch: Decodable, Sendable {
            var reactions: [Lossy<ReactionData>]?
        }
        struct MembershipData: Decodable, Sendable {}
        struct MembershipBatch: Decodable, Sendable {
            var memberships: [Lossy<MembershipData>]?
        }
        struct SpaceData: Decodable, Sendable {
            var space: Lossy<SpaceDTO>?
        }
        struct SpaceBatch: Decodable, Sendable {
            var spaces: [Lossy<SpaceData>]?
        }

        var name: String?
        var eventTime: String?
        var eventType: String?
        var messageCreatedEventData: MessageData?
        var messageUpdatedEventData: MessageData?
        var messageDeletedEventData: MessageData?
        var messageBatchCreatedEventData: MessageBatch?
        var messageBatchUpdatedEventData: MessageBatch?
        var messageBatchDeletedEventData: MessageBatch?
        var reactionCreatedEventData: ReactionData?
        var reactionDeletedEventData: ReactionData?
        var reactionBatchCreatedEventData: ReactionBatch?
        var reactionBatchDeletedEventData: ReactionBatch?
        var membershipCreatedEventData: MembershipData?
        var membershipUpdatedEventData: MembershipData?
        var membershipDeletedEventData: MembershipData?
        var membershipBatchCreatedEventData: MembershipBatch?
        var membershipBatchUpdatedEventData: MembershipBatch?
        var membershipBatchDeletedEventData: MembershipBatch?
        var spaceUpdatedEventData: SpaceData?
        var spaceBatchUpdatedEventData: SpaceBatch?
    }

    struct SpacesPage: Decodable, Sendable {
        var spaces: [Lossy<SpaceDTO>]?
        var nextPageToken: String?
    }

    struct MessagesPage: Decodable, Sendable {
        var messages: [Lossy<MessageDTO>]?
        var nextPageToken: String?
    }

    struct MessageSearchPage: Decodable, Sendable {
        struct Hit: Decodable, Sendable {
            var message: MessageDTO
        }

        var results: [Lossy<Hit>]?
        var nextPageToken: String?
    }

    struct SpaceEventsPage: Decodable, Sendable {
        var spaceEvents: [Lossy<SpaceEventDTO>]?
        var nextPageToken: String?
    }

    struct MembershipsPage: Decodable, Sendable {
        var memberships: [Lossy<MembershipDTO>]?
        var nextPageToken: String?
    }

    struct CustomEmojisPage: Decodable, Sendable {
        var customEmojis: [Lossy<CustomEmojiDTO>]?
        var nextPageToken: String?
    }
}
