import ChatModel
import ChatNet
import Foundation
import Testing

@testable import GoogleChat

@Suite struct MappingTests {
    func messageName(_ raw: String) -> MessageName { MessageName(unchecked: raw) }

    // MARK: spaces

    @Test func spacesMapAndSkipInvalidItems() async throws {
        let (client, _) = clientServing("spaces_list")
        let page = try await client.listSpaces(pageSize: 100, pageToken: nil)
        #expect(
            page.items.map(\.name.rawValue) == [
                "spaces/AAAAThreaded", "spaces/AAAAGrouped", "spaces/AAAAUnthreaded", "spaces/DMDMDM", "spaces/GCGCGC",
            ])
        #expect(page.nextPageToken == "page/2+token==")

        let engineering = page.items[0]
        #expect(engineering.type == .space)
        #expect(engineering.displayName == "Engineering")
        #expect(engineering.isThreaded)
        #expect(engineering.isExternalUserAllowed)
        #expect(engineering.lastActiveTime == ts("2026-10-14T09:15:30.123456Z"))
        #expect(engineering.createTime == ts("2025-01-02T03:04:05Z"))
        #expect(engineering.historyOn == true)
        #expect(page.items[1].historyOn == nil)

        #expect(page.items[1].isThreaded)
        #expect(!page.items[2].isThreaded)

        let dm = page.items[3]
        #expect(dm.type == .directMessage)
        #expect(dm.displayName == "")
        #expect(dm.isSingleUserBotDM)
        #expect(dm.lastActiveTime == nil)
        #expect(dm.historyOn == false)

        #expect(!page.items[4].isThreaded)
        #expect(page.items[4].type == .groupChat)
    }

    @Test func emptyNextPageTokenIsNil() async throws {
        let (client, _) = clientServing("custom_emojis_list")
        #expect(try await client.listCustomEmojis(pageToken: nil).nextPageToken == nil)
    }

    @Test func getSpaceThrowsDecodingForUnknownType() async {
        let transport = StubTransport(status: 200, body: Data(#"{"name":"spaces/AAAA","spaceType":"FUTURE"}"#.utf8))
        let error = await thrownError { try await makeClient(transport).getSpace(testSpace) }
        #expect(error == .decoding(path: "spaceType"))
    }

    @Test func getSpaceThrowsDecodingForInvalidName() async {
        let transport = StubTransport(status: 200, body: Data(#"{"name":"spaces/","spaceType":"SPACE"}"#.utf8))
        let error = await thrownError { try await makeClient(transport).getSpace(testSpace) }
        #expect(error == .decoding(path: "name"))
    }

    // MARK: messages

    @Test func messageListSkipsInvalidItems() async throws {
        let (client, _) = clientServing("messages_list")
        let page = try await client.listMessages(
            in: testSpace, window: .init(), thread: nil, order: .ascending, pageSize: 10, showDeleted: true,
            pageToken: nil)
        #expect(
            page.items.map(\.name.rawValue) == [
                "spaces/AAAA/messages/GOOD1", "spaces/AAAA/messages/NOSENDER", "spaces/AAAA/messages/CARD",
                "spaces/AAAA/messages/TOMB",
            ])
        #expect(page.nextPageToken == "msgs-next")
    }

    @Test func messageSenderAndCardsFallback() async throws {
        let (client, _) = clientServing("messages_list")
        let items = try await client.listMessages(
            in: testSpace, window: .init(), thread: nil, order: .ascending, pageSize: 10, showDeleted: true,
            pageToken: nil
        ).items

        #expect(items[0].sender == User(name: UserName(unchecked: "users/1001"), type: .bot))
        #expect(items[0].text == "first")
        #expect(items[0].formattedText == "*first*")
        #expect(items[1].formattedText == nil)

        #expect(items[1].sender == User(name: UserName(unchecked: "users/unknown"), type: .human))
        #expect(items[1].cardsFallbackText == nil)

        #expect(items[2].cardsFallbackText == "Card text")
        #expect(items[2].text == "")

        #expect(items[3].deleteTime == ts("2026-10-14T12:30:00Z"))
        #expect(items[3].isDeleted)
        #expect(items[3].formattedText == nil)
        #expect(items[0].deleteTime == nil)
    }

    @Test func fullMessageCoreFields() async throws {
        let (client, _) = clientServing("message_full")
        let message = try await client.getMessage(messageName("spaces/AAAA/messages/MSG1.MSG1"))

        #expect(message.name.rawValue == "spaces/AAAA/messages/MSG1.MSG1")
        #expect(message.sender.displayName == "Alice Example")
        #expect(message.createTime == ts("2026-10-14T12:00:00.250Z"))
        #expect(message.lastUpdateTime == ts("2026-10-14T12:05:00Z"))
        #expect(message.deleteTime == ts("2026-10-14T13:00:00Z"))
        #expect(message.thread?.rawValue == "spaces/AAAA/threads/THR1")
        #expect(message.isThreadReply)
        #expect(message.cardsFallbackText == "Card says hello")
        #expect(message.privateViewer?.rawValue == "users/1002")
        #expect(message.clientMessageID == "client-abc-123")
        #expect(
            message.quoted
                == QuotedMessage(
                    name: messageName("spaces/AAAA/messages/QUOTED"), lastUpdateTime: ts("2026-10-14T11:00:00Z"),
                    snapshotSender: UserName(unchecked: "users/1003"), snapshotText: "original words"))
        #expect(message.space == testSpace)
    }

    @Test func allAnnotationKindsMapAndInvalidOnesAreDropped() async throws {
        let (client, _) = clientServing("message_full")
        let message = try await client.getMessage(messageName("spaces/AAAA/messages/MSG1.MSG1"))
        #expect(message.text.utf16.count == 58)
        #expect(
            message.annotations == [
                Annotation(kind: .userMention(UserName(unchecked: "users/1002")), startIndex: 4, length: 4),
                Annotation(kind: .richLink(URL(string: "https://example.com/doc")!), startIndex: 15, length: 23),
                Annotation(
                    kind: .customEmoji(CustomEmojiName(unchecked: "customEmojis/PARTY1"), shortcode: ":party:"),
                    startIndex: 39, length: 7),
                Annotation(kind: .slashCommand, startIndex: 47, length: 5),
                Annotation(kind: .userMention(.all), startIndex: 56, length: 2),
                Annotation(kind: .customEmoji(nil, shortcode: ":only_shortcode:"), startIndex: 39, length: 7),
            ])
    }

    @Test func attachmentsMapSourcesAndDropUnusable() async throws {
        let (client, _) = clientServing("message_full")
        let message = try await client.getMessage(messageName("spaces/AAAA/messages/MSG1.MSG1"))
        #expect(message.attachments.count == 2)

        let uploaded = message.attachments[0]
        #expect(uploaded.source == .uploaded(MediaResourceName("AbCd_Ef-12=")!))
        #expect(uploaded.contentName == "photo.png")
        #expect(uploaded.contentType == "image/png")
        #expect(uploaded.thumbnailURI == URL(string: "https://chat.google.com/api/get_attachment_url?thumb=1"))
        #expect(uploaded.downloadURI == nil)

        let drive = message.attachments[1]
        #expect(drive.source == .drive(fileID: "FILE1"))
        #expect(drive.downloadURI == URL(string: "https://drive.google.com/file/d/FILE1/view"))
        #expect(drive.thumbnailURI == nil)
    }

    @Test func gifsKeepOnlyHTTPS() async throws {
        let (client, _) = clientServing("message_full")
        let message = try await client.getMessage(messageName("spaces/AAAA/messages/MSG1.MSG1"))
        #expect(message.gifURLs == [URL(string: "https://media.tenor.test/a.gif")!])
    }

    @Test func reactionsKeepUnicodeAndValidCustomAndClampCounts() async throws {
        let (client, _) = clientServing("message_full")
        let message = try await client.getMessage(messageName("spaces/AAAA/messages/MSG1.MSG1"))
        #expect(
            message.reactions == [
                ReactionSummary(emoji: .unicode("👍"), count: 3),
                ReactionSummary(
                    emoji: .custom(CustomEmojiName(unchecked: "customEmojis/PARTY1"), shortcode: ":party:"), count: 2),
                ReactionSummary(
                    emoji: .custom(CustomEmojiName(unchecked: "customEmojis/NOSHORT"), shortcode: nil), count: 1),
                ReactionSummary(emoji: .unicode("🎉"), count: 0),
                ReactionSummary(emoji: .unicode("😀"), count: 0),
            ])
    }

    @Test func messageWithInvalidNameOrMissingCreateTimeThrowsDecodingWhenSingle() async {
        for (json, path) in [
            (#"{"name":"spaces/AAAA","createTime":"2026-10-14T12:00:00Z"}"#, "name"),
            (#"{"name":"spaces/AAAA/messages/M1"}"#, "createTime"),
            (#"{"name":"spaces/AAAA/messages/M1","createTime":"soon"}"#, "createTime"),
        ] {
            let transport = StubTransport(status: 200, body: Data(json.utf8))
            let error = await thrownError {
                try await makeClient(transport).getMessage(messageName("spaces/AAAA/messages/M1"))
            }
            #expect(error == .decoding(path: path))
        }
    }

    @Test func createMessageReturnsMappedServerMessage() async throws {
        let transport = StubTransport(status: 200, body: fixture("message_full"))
        let created = try await makeClient(transport).createMessage(
            NewMessage(space: testSpace, text: "x", requestID: UUID()))
        #expect(created.message?.clientMessageID == "client-abc-123")
    }

    @Test func incompleteCreateResponseStillYieldsTheName() async throws {
        let body = Data(#"{"name":"\#(testSpace.rawValue)/messages/abc.def"}"#.utf8)
        let created = try await makeClient(StubTransport(status: 200, body: body)).createMessage(
            NewMessage(space: testSpace, text: "x", requestID: UUID()))
        #expect(created.name.rawValue == "\(testSpace.rawValue)/messages/abc.def")
        #expect(created.message == nil)
    }

    @Test func createResponseForAnotherSpaceIsRejected() async {
        let body = Data(#"{"name":"spaces/OTHER/messages/abc"}"#.utf8)
        await #expect(throws: ChatAPIError.decoding(path: "name")) {
            try await makeClient(StubTransport(status: 200, body: body)).createMessage(
                NewMessage(space: testSpace, text: "x", requestID: UUID()))
        }
    }

    // MARK: memberships, emojis, small resources

    @Test func membershipsMapTolerantlyAndSkipUnusable() async throws {
        let (client, _) = clientServing("members_list")
        let page = try await client.listMemberships(in: testSpace, pageToken: nil)
        #expect(page.items.count == 2)
        #expect(page.items[0].role == .manager)
        #expect(page.items[0].state == .joined)
        #expect(page.items[0].member.displayName == "Alice")
        #expect(page.items[1].role == .unspecified)
        #expect(page.items[1].state == .unspecified)
        #expect(page.items[1].member.type == .bot)
    }

    @Test func assistantManagersKeepTheirRole() async throws {
        let body = Data(
            #"{"memberships":[{"name":"\#(testSpace.rawValue)/members/1","state":"JOINED","role":"ROLE_ASSISTANT_MANAGER","member":{"name":"users/1","displayName":"Ann","type":"HUMAN"}}]}"#
                .utf8)
        let page = try await makeClient(StubTransport(status: 200, body: body)).listMemberships(
            in: testSpace, pageToken: nil)
        #expect(page.items.map(\.role) == [.assistantManager])
    }

    @Test func customEmojisMapAndSkipInvalid() async throws {
        let (client, _) = clientServing("custom_emojis_list")
        let page = try await client.listCustomEmojis(pageToken: nil)
        #expect(
            page.items == [
                CustomEmoji(
                    name: CustomEmojiName(unchecked: "customEmojis/PARTY1"), shortcode: ":party:",
                    temporaryImageURL: URL(string: "https://lh3.googleusercontent.test/emoji.png")),
                CustomEmoji(
                    name: CustomEmojiName(unchecked: "customEmojis/INSECURE"), shortcode: ":insecure:",
                    temporaryImageURL: nil),
            ])
    }

    @Test(
        arguments: [
            (#"{"notificationSetting":"FOR_YOU","muteSetting":"MUTED"}"#, NotificationLevel.forYou, true),
            (#"{"notificationSetting":"OFF","muteSetting":"UNMUTED"}"#, .off, false),
            (#"{"notificationSetting":"MAIN_CONVERSATIONS"}"#, .mainConversations, false),
            (#"{"notificationSetting":"SOMETHING_NEW","muteSetting":"MUTED"}"#, .all, true),
            (#"{}"#, .all, false),
        ])
    func notificationSetting(json: String, level: NotificationLevel, muted: Bool) async throws {
        let transport = StubTransport(status: 200, body: Data(json.utf8))
        let setting = try await makeClient(transport).getNotificationSetting(testSpace)
        #expect(setting == SpaceNotificationSetting(level: level, isMuted: muted))
    }

    @Test func readStatesParseTimestampsAndTolerateAbsence() async throws {
        let withTime = StubTransport(status: 200, body: Data(#"{"lastReadTime":"2026-10-14T12:00:00.5Z"}"#.utf8))
        #expect(try await makeClient(withTime).getSpaceReadState(testSpace) == ts("2026-10-14T12:00:00.500Z"))

        let without = StubTransport(status: 200, body: Data("{}".utf8))
        #expect(try await makeClient(without).getSpaceReadState(testSpace) == nil)

        let bad = StubTransport(status: 200, body: Data(#"{"lastReadTime":"nope"}"#.utf8))
        let error = await thrownError { try await makeClient(bad).getSpaceReadState(testSpace) }
        #expect(error == .decoding(path: "lastReadTime"))
    }

    // MARK: space events

    func events() async throws -> Page<TimedSpaceEvent> {
        let (client, _) = clientServing("space_events")
        return try await client.listSpaceEvents(
            in: testSpace, types: SpaceEvent.pollTypes, start: ts("2026-10-14T00:00:00Z"),
            end: ts("2026-10-15T00:00:00Z"),
            pageToken: nil)
    }

    @Test func eventsAreFlattenedInOrderWithTheEventTime() async throws {
        let page = try await events()
        func label(_ event: SpaceEvent) -> String {
            switch event {
            case .messageCreated(let m): "created \(m.name.id(at: 1))"
            case .messageUpdated(let m): "updated \(m.name.id(at: 1))"
            case .messageDeleted(let m): "deleted \(m.name.id(at: 1))"
            case .reactionsChanged(let name): "reactions \(name.id(at: 1))"
            case .membershipsChanged: "memberships"
            case .spaceUpdated(let space): "space \(space.displayName)"
            }
        }
        let summary = page.items.map { "\($0.time) \(label($0.event))" }
        #expect(
            summary == [
                "2026-10-14T10:00:00Z created M1",
                "2026-10-14T10:01:00Z created M2",
                "2026-10-14T10:01:00Z created M3",
                "2026-10-14T10:02:00Z updated M1",
                "2026-10-14T10:03:00Z deleted M2",
                "2026-10-14T10:04:00Z reactions M1",
                "2026-10-14T10:04:00Z reactions M3",
                "2026-10-14T10:05:00Z reactions M1",
                "2026-10-14T10:06:00Z memberships",
                "2026-10-14T10:06:00Z memberships",
                "2026-10-14T10:07:00Z memberships",
                "2026-10-14T10:08:00Z space Renamed",
                "2026-10-14T10:09:00Z space Renamed twice",
            ])
        #expect(page.nextPageToken == "events-next")
    }

    @Test func reactionEventsDeduplicatePerEventNotAcrossEvents() async throws {
        let page = try await events()
        let reactionEvents = page.items.filter {
            if case .reactionsChanged = $0.event { true } else { false }
        }
        #expect(reactionEvents.count == 3)
        #expect(
            reactionEvents.map(\.event) == [
                .reactionsChanged(messageName("spaces/AAAA/messages/M1")),
                .reactionsChanged(messageName("spaces/AAAA/messages/M3")),
                .reactionsChanged(messageName("spaces/AAAA/messages/M1")),
            ])
    }

    @Test func deletedEventMessageIsATombstoneAtEventTime() async throws {
        let page = try await events()
        guard case .messageDeleted(let message) = page.items[4].event else {
            Issue.record("expected messageDeleted")
            return
        }
        #expect(message.deleteTime == ts("2026-10-14T10:03:00Z"))
        #expect(message.sender == User(name: UserName(unchecked: "users/unknown"), type: .human))
        #expect(message.isDeleted)
    }

    @Test func unknownEventTypesAndBadEventTimesAreSkipped() async throws {
        let page = try await events()
        let times = Set(page.items.map(\.time))
        #expect(!times.contains(ts("2026-10-14T10:10:00Z")))
        #expect(page.items.count == 13)
    }

    @Test func mappingHelpersRejectMalformedReactionNames() {
        #expect(Mapping.messageName(ofReaction: "spaces/A/messages/M/reactions/R")?.rawValue == "spaces/A/messages/M")
        #expect(Mapping.messageName(ofReaction: "spaces/A/messages/M/reactions") == nil)
        #expect(Mapping.messageName(ofReaction: "spaces/A/messages/M/other/R") == nil)
        #expect(Mapping.messageName(ofReaction: "spaces/A/reactions/R") == nil)
        #expect(Mapping.messageName(ofReaction: "spaces/A/messages/../reactions/R") == nil)
        #expect(Mapping.messageName(ofReaction: nil) == nil)
    }
}
