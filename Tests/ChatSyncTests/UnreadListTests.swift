import ChatModel
import FakeChatServer
import Foundation
import Testing

@testable import ChatSync

struct UnreadListTests {
    @Test func listsTheSameMessagesTheCountDoesIncludingRepliesInAReadThread() async throws {
        let rig = try SyncRig()
        // The space is read up to the thread's first message, and the thread up to its first reply.
        rig.server.setReadState(rig.alice, space: rig.team, lastReadTime: rig.first.createTime)
        rig.server.advance(.seconds(5))
        let read = rig.server.post("read reply", in: rig.team, from: .account(rig.bob), thread: rig.thread)
        rig.server.advance(.seconds(5))
        let reply = rig.server.post("new reply", in: rig.team, from: .account(rig.bob), thread: rig.thread)
        rig.server.advance(.seconds(5))
        _ = rig.server.post("my reply", in: rig.team, from: .account(rig.alice), thread: rig.thread)
        rig.server.advance(.seconds(5))
        let topLevel = rig.server.post("new topic", in: rig.team, from: .account(rig.bob))
        rig.server.setThreadReadState(rig.alice, thread: rig.thread, lastReadTime: read.createTime)
        rig.server.advance(.seconds(5))

        try await rig.syncSpaces()
        try await rig.engine.syncMessages(rig.team, rig.generation)
        try await rig.engine.syncReadState(rig.team, rig.generation)
        try await rig.engine.syncThreadReadStates([rig.thread], rig.generation)

        let unread = try rig.engine.unread(in: rig.team)
        #expect(unread.messages.map(\.name) == [reply.name, topLevel.name])
        #expect(unread.roots[rig.thread]?.name == rig.first.name)
        let summary = try #require(try rig.engine.snapshotSpaces().first { $0.name == rig.team })
        #expect(summary.unreadCount == unread.messages.count)
    }
}
