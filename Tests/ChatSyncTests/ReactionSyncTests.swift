import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

struct ReactionSyncTests {
    func rig() async throws -> (Harness, SpaceName, Message, Reactions) {
        let h = Harness()
        let team = h.server.addSpace(.space, displayName: "Team", members: [h.alice, h.bob])
        let message = h.server.post("ship it", in: team, from: .account(h.bob))
        h.server.advance(.seconds(5))
        try await h.syncAll()
        let api = GoogleChatClient(transport: h.server.makeTransport(), tokens: StaticTokens(token: h.alice.token))
        let reactions = Reactions(
            api: api, store: h.store, gate: h.gate, clock: ServerClock(server: h.server), me: h.alice.user.name)
        return (h, team, message, reactions)
    }

    @Test func toggleAddsThenRemovesAndUpdatesTheSummary() async throws {
        let (h, _, message, reactions) = try await rig()
        try await reactions.toggle(.unicode("🚀"), on: message.name, h.generation)
        #expect(reactions.mine(on: message.name)[.unicode("🚀")] != nil)
        #expect(try h.store.message(message.name)?.reactions == [ReactionSummary(emoji: .unicode("🚀"), count: 1)])
        #expect(h.server.message(message.name)?.reactions.first?.count == 1)

        try await reactions.toggle(.unicode("🚀"), on: message.name, h.generation)
        #expect(reactions.mine(on: message.name).isEmpty)
        #expect(try h.store.message(message.name)?.reactions.isEmpty == true)
        #expect(h.server.message(message.name)?.reactions.isEmpty == true)
    }

    @Test func removingAReactionThatsAlreadyGoneSucceeds() async throws {
        let (h, _, message, reactions) = try await rig()
        try await reactions.toggle(.unicode("🚀"), on: message.name, h.generation)
        let created = try #require(reactions.mine(on: message.name)[.unicode("🚀")])
        h.server.removeReaction(created)

        try await reactions.toggle(.unicode("🚀"), on: message.name, h.generation)
        #expect(reactions.mine(on: message.name).isEmpty)
        #expect(try h.store.message(message.name)?.reactions.isEmpty == true)
    }

    @Test func othersReactionsCountButArentMine() async throws {
        let (h, _, message, reactions) = try await rig()
        h.server.react(message.name, emoji: .unicode("👍"), by: .account(h.bob))
        h.server.react(message.name, emoji: .unicode("🎉"), by: .account(h.alice))
        try await reactions.refreshMine([message.name], h.generation, force: true)
        #expect(Set(reactions.mine(on: message.name).keys) == [.unicode("🎉")])

        try await reactions.toggle(.unicode("👍"), on: message.name, h.generation)
        #expect(h.server.message(message.name)?.reactions.first { $0.emoji == .unicode("👍") }?.count == 2)
    }

    @Test func duplicateCreateLearnsTheExistingReaction() async throws {
        let (h, _, message, reactions) = try await rig()
        h.server.react(message.name, emoji: .unicode("👍"), by: .account(h.alice))
        try await reactions.toggle(.unicode("👍"), on: message.name, h.generation)
        #expect(reactions.mine(on: message.name)[.unicode("👍")] != nil)
        #expect(h.server.message(message.name)?.reactions.first?.count == 1)
    }

    @Test func customEmojiReactionsAndList() async throws {
        let (h, _, message, reactions) = try await rig()
        let parrot = h.server.addCustomEmoji(shortcode: "party_parrot")
        try await reactions.refreshCustomEmojis(h.generation)
        #expect(reactions.customEmojis.map(\.name) == [parrot])
        try await reactions.toggle(.custom(parrot, shortcode: ":party_parrot:"), on: message.name, h.generation)
        #expect(reactions.mine(on: message.name).count == 1)
    }

    @Test func retiredGenerationChangesNothing() async throws {
        let (h, _, message, reactions) = try await rig()
        let old = h.generation
        h.gate.retire()
        await #expect(throws: SyncError.retired) { try await reactions.toggle(.unicode("🚀"), on: message.name, old) }
        #expect(try h.store.message(message.name)?.reactions.isEmpty == true)
    }

    @Test func writesArePacedPerSpace() async throws {
        let (h, _, message, reactions) = try await rig()
        let start = h.server.now
        try await reactions.pace(message.space)
        try await reactions.pace(message.space)
        try await reactions.pace(message.space)
        #expect(try #require(reactions.lastWrite(message.space)) >= start.adding(.milliseconds(500)))
    }
}
