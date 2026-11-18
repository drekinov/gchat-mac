import ChatModel
import Foundation
import Testing

@testable import FakeChatServer

struct PerUserStateTests {
    let h = Harness()

    var readStatePath: String { "users/me/\(h.space.rawValue)/spaceReadState" }

    func patch(_ time: String, mask: String? = "lastReadTime", as account: FakeAccount? = nil) async throws -> Call {
        let query = mask.map { ["updateMask": $0] } ?? [:]
        return try await h.call(
            .patch, readStatePath, query: query, body: ["lastReadTime": time], as: account ?? h.alice)
    }

    @Test func readStateOmitsLastReadTimeUntilSet() async throws {
        let call = try await h.get(readStatePath, as: h.alice)
        #expect(call.status == 200)
        #expect(call.json["name"] as? String == "\(h.alice.user.name.rawValue)/\(h.space.rawValue)/spaceReadState")
        #expect(call.json["lastReadTime"] == nil)
    }

    @Test func seededReadStateIsPerAccount() async throws {
        let time = ts("2026-02-01T00:00:00Z")
        h.server.setReadState(h.alice, space: h.space, lastReadTime: time)
        #expect(try await h.get(readStatePath, as: h.alice).json["lastReadTime"] as? String == time.rfc3339)
        #expect(try await h.get(readStatePath, as: h.bob).json["lastReadTime"] == nil)
        h.server.setReadState(h.alice, space: h.space, lastReadTime: nil)
        #expect(try await h.get(readStatePath, as: h.alice).json["lastReadTime"] == nil)
    }

    @Test func patchStoresAndEchoesTheValue() async throws {
        let messages = h.seed(3)
        let call = try await patch(messages[1].createTime.rfc3339)
        #expect(call.status == 200)
        #expect(call.json["lastReadTime"] as? String == messages[1].createTime.rfc3339)
        #expect(
            try await h.get(readStatePath, as: h.alice).json["lastReadTime"] as? String
                == messages[1].createTime.rfc3339)
    }

    @Test func patchLaterThanTheLatestMessageIsCoerced() async throws {
        let messages = h.seed(3)
        let call = try await patch("2099-01-01T00:00:00Z")
        #expect(call.json["lastReadTime"] as? String == messages[2].createTime.rfc3339)
        #expect(
            try await h.get(readStatePath, as: h.alice).json["lastReadTime"] as? String
                == messages[2].createTime.rfc3339)
    }

    @Test func patchRequiresTheUpdateMaskAndAValidBody() async throws {
        h.seed(1)
        #expect(try await patch("2026-01-01T00:00:00Z", mask: nil).status == 400)
        #expect(try await patch("2026-01-01T00:00:00Z", mask: "name").status == 400)
        #expect(try await patch("yesterday").status == 400)
        let empty = try await h.call(
            .patch, readStatePath, query: ["updateMask": "lastReadTime"], body: [:], as: h.alice)
        #expect(empty.status == 400)
    }

    @Test func patchByNonMemberIs403() async throws {
        #expect(try await patch("2026-01-01T00:00:00Z", as: h.carol).status == 403)
    }

    @Test func otherUsersReadStateIsForbidden() async throws {
        let path = "\(h.bob.user.name.rawValue)/\(h.space.rawValue)/spaceReadState"
        #expect(
            try await h.get("users/\(h.alice.user.name.id(at: 0))/\(h.space.rawValue)/spaceReadState", as: h.alice)
                .status == 200)
        #expect(try await h.get(path, as: h.alice).status == 403)
    }

    @Test func threadReadStateIsSeededAndNeedsAnExistingThread() async throws {
        let root = h.server.post("root", in: h.space, from: .account(h.bob))
        let thread = try #require(root.thread)
        let path = "users/me/\(h.space.rawValue)/threads/\(thread.id(at: 1))/threadReadState"
        #expect(try await h.get(path, as: h.alice).json["lastReadTime"] == nil)

        let time = ts("2026-02-01T00:00:00Z")
        h.server.setThreadReadState(h.alice, thread: thread, lastReadTime: time)
        let call = try await h.get(path, as: h.alice)
        #expect(call.json["lastReadTime"] as? String == time.rfc3339)
        #expect(call.json["name"] as? String == "\(h.alice.user.name.rawValue)/\(thread.rawValue)/threadReadState")
        #expect(try await h.get(path, as: h.bob).json["lastReadTime"] == nil)
        #expect(try await h.call(.patch, path, as: h.alice).status == 400)
    }

    @Test func notificationSettingDefaultsToAllUnmuted() async throws {
        let path = "users/me/\(h.space.rawValue)/spaceNotificationSetting"
        let call = try await h.get(path, as: h.alice)
        #expect(call.json["notificationSetting"] as? String == "ALL")
        #expect(call.json["muteSetting"] as? String == "UNMUTED")
    }

    @Test func notificationSettingIsSeededPerAccount() async throws {
        let path = "users/me/\(h.space.rawValue)/spaceNotificationSetting"
        h.server.setNotificationSetting(
            h.alice, space: h.space, SpaceNotificationSetting(level: .forYou, isMuted: true))
        let call = try await h.get(path, as: h.alice)
        #expect(call.json["notificationSetting"] as? String == "FOR_YOU")
        #expect(call.json["muteSetting"] as? String == "MUTED")
        #expect(try await h.get(path, as: h.bob).json["muteSetting"] as? String == "UNMUTED")
    }

    @Test func customEmojisCarryTemporaryImageUris() async throws {
        let name = h.server.addCustomEmoji(shortcode: "party")
        let emoji = try #require(try await h.get("customEmojis", as: h.alice).items("customEmojis").first)
        #expect(emoji["name"] as? String == name.rawValue)
        #expect(emoji["emojiName"] as? String == ":party:")
        #expect(emoji["uid"] is String)
        #expect(emoji["temporaryImageUri"] as? String == "https://fake-emoji.example/\(name.id(at: 0)).png")
    }

    @Test func customEmojiReactionsAndAnnotationsUseTheRegisteredEmoji() async throws {
        let name = h.server.addCustomEmoji(shortcode: "party")
        let message = h.server.post(
            "x :party:", in: h.space, from: .account(h.alice),
            annotations: [Annotation(kind: .customEmoji(name, shortcode: "party"), startIndex: 2, length: 7)])
        h.server.react(message.name, emoji: .custom(name, shortcode: nil), by: .account(h.bob))
        let wire = try await h.get(message.name.rawValue, as: h.alice).json
        let metadata = (wire["annotations"] as? [[String: Any]])?.first?["customEmojiMetadata"] as? [String: Any]
        #expect((metadata?["customEmoji"] as? [String: Any])?["emojiName"] as? String == ":party:")
        let summary = (wire["emojiReactionSummaries"] as? [[String: Any]])?.first
        let custom = (summary?["emoji"] as? [String: Any])?["customEmoji"] as? [String: Any]
        #expect(custom?["name"] as? String == name.rawValue)
        #expect(custom?["emojiName"] as? String == ":party:")
    }
}
