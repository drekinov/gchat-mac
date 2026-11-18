import ChatModel
import ChatStore
import Foundation
import Testing

@testable import ChatSync

/// Snapshots re-decrypt only the spaces a commit touched.
struct EfficiencyTests {
    @Test func unchangedSpacesAreNotReRead() async throws {
        let h = Harness()
        var spaces: [SpaceName] = []
        for index in 0..<10 {
            let space = h.server.addSpace(.space, displayName: "S\(index)", members: [h.alice, h.bob])
            h.server.post("hello \(index)", in: space, from: .account(h.bob))
            spaces.append(space)
        }
        h.server.advance(.seconds(5))
        try await h.syncAll()

        var digests: [SpaceName: SyncEngine.SpaceDigest] = [:]
        let first = try h.engine.snapshotSpaces(changed: nil, digests: &digests)
        #expect(first.count == 10)
        #expect(digests.count == 10)

        h.server.post("new", in: spaces[3], from: .account(h.bob))
        h.server.advance(.seconds(5))
        try await h.engine.syncMessages(spaces[3], h.generation)

        let stale = digests
        let second = try h.engine.snapshotSpaces(changed: [spaces[3]], digests: &digests)
        #expect(second.first { $0.name == spaces[3] }?.lastMessagePreview == "new")
        #expect(second.first { $0.name == spaces[3] }?.unreadCount == 2)
        for space in spaces where space != spaces[3] { #expect(digests[space] == stale[space]) }
    }

    @Test func readTimeChangeRecomputesWithoutBeingListed() async throws {
        let h = Harness()
        let team = h.server.addSpace(.space, displayName: "Team", members: [h.alice, h.bob])
        h.server.post("one", in: team, from: .account(h.bob))
        h.server.advance(.seconds(5))
        try await h.syncAll()
        var digests: [SpaceName: SyncEngine.SpaceDigest] = [:]
        #expect(try h.engine.snapshotSpaces(changed: nil, digests: &digests).first?.unreadCount == 1)

        try h.store.write(gate: h.gate, generation: h.generation) {
            $0.append(.setReadState(team, h.server.now))
        }
        #expect(try h.engine.snapshotSpaces(changed: [], digests: &digests).first?.unreadCount == 0)
    }
}
