import ChatModel
import ChatStore
import FakeChatServer
import Foundation
import GoogleChat
import Testing

@testable import ChatSync

/// Direct engine and client calls, with no session running.
extension DailyUseTests {
    @Test func onlyAnOpenThreadAdvancesAndNewerRemoteReadStateWins() async throws {
        let rig = try SyncRig()
        try await rig.syncSpaces()
        let time = rig.first.createTime
        let position = ThreadReadPosition(thread: rig.thread, upTo: time)
        try await rig.engine.markThreadRead(position, rig.generation) { false }
        #expect(rig.server.requests.allSatisfy { $0.method != "PATCH" })
        try await rig.engine.markThreadRead(position, rig.generation) { true }
        #expect(try rig.store.threadReadState(rig.thread) == time)
        #expect(try await rig.engine.api.getThreadReadState(rig.thread) == time)
        let newer = rig.server.now
        rig.server.setThreadReadState(rig.alice, thread: rig.thread, lastReadTime: newer)
        try await rig.engine.markThreadRead(position, rig.generation) { true }
        #expect(try rig.store.threadReadState(rig.thread) == newer)
        #expect(rig.server.requests.filter { $0.method == "PATCH" }.count == 1)
    }

    @Test func searchPagesStayBoundToAccountAndQuery() async throws {
        let rig = try SyncRig()
        let server = rig.server
        let other = server.addSpace(.space, members: [rig.bob])
        server.post("needle hidden", in: other, from: .account(rig.bob))
        let old = server.post("needle first", in: rig.team, from: .account(rig.bob))
        let new = server.post("needle last", in: rig.team, from: .account(rig.alice))
        let api = rig.engine.api
        let page = try await api.searchMessages("needle", pageSize: 1, pageToken: nil)
        #expect(page.items.map(\.name) == [new.name])
        let token = try #require(page.nextPageToken)
        let next = try await api.searchMessages("needle", pageSize: 1, pageToken: token)
        #expect(next.items.map(\.name) == [old.name])
        #expect(next.nextPageToken == nil)
        await #expect(throws: ChatAPIError.self) {
            try await api.searchMessages("different", pageSize: 1, pageToken: token)
        }
        let bob = GoogleChatClient(transport: server.makeTransport(), tokens: StaticTokens(token: rig.bob.token))
        await #expect(throws: ChatAPIError.self) {
            try await bob.searchMessages("needle", pageSize: 1, pageToken: token)
        }
    }
}
