import Foundation
import Testing

@testable import ChatModel

struct MembershipTests {
    @Test func storedRolesDecodeAndUnknownOnesReadAsUnspecified() throws {
        let decoder = JSONDecoder()
        let roles = try decoder.decode(
            [Membership.Role].self,
            from: Data(#"["ROLE_MANAGER","ROLE_ASSISTANT_MANAGER","ROLE_SOMETHING_NEW"]"#.utf8))
        #expect(roles == [.manager, .assistantManager, .unspecified])
        let encoded = try JSONEncoder().encode([Membership.Role.assistantManager])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["ROLE_ASSISTANT_MANAGER"]"#)
    }

    @Test func aStoredMembershipWithAnUnknownRoleStillDecodes() throws {
        let membership = Membership(
            name: MembershipName(unchecked: "spaces/A/members/1"),
            member: User(name: UserName(unchecked: "users/1"), displayName: "Ann"), role: .manager)
        var json = try #require(String(data: JSONEncoder().encode(membership), encoding: .utf8))
        json = json.replacingOccurrences(of: "ROLE_MANAGER", with: "ROLE_SOMETHING_NEW")
        let decoded = try JSONDecoder().decode(Membership.self, from: Data(json.utf8))
        #expect(decoded.role == .unspecified)
        #expect(decoded.member.displayName == "Ann")
    }
}

struct NewestVisibleReplyTests {
    let thread = ThreadName(unchecked: "spaces/A/threads/t")

    func reply(_ id: Int, at seconds: Int64, deleted: Bool = false) -> Message {
        Message(
            name: MessageName(unchecked: "spaces/A/messages/\(id)"),
            sender: User(name: UserName(unchecked: "users/1"), displayName: "Ann"),
            createTime: Timestamp(seconds: seconds), deleteTime: deleted ? Timestamp(seconds: seconds + 1) : nil,
            thread: thread, isThreadReply: true)
    }

    @Test func nothingOnScreenGivesNil() {
        #expect(Message.newestVisibleReply(in: [reply(1, at: 10)], visible: []) == nil)
    }

    @Test func picksTheNewestVisibleRegardlessOfOrder() {
        let replies = [reply(3, at: 30), reply(1, at: 10), reply(2, at: 20)]
        let visible: Set = [replies[1].name, replies[2].name]
        #expect(Message.newestVisibleReply(in: replies, visible: visible) == Timestamp(seconds: 20))
    }

    @Test func ignoresDeletedRepliesAndNamesNotInTheThread() {
        let replies = [reply(1, at: 10), reply(2, at: 20, deleted: true)]
        let stranger = MessageName(unchecked: "spaces/A/messages/99")
        let visible: Set = [replies[0].name, replies[1].name, stranger]
        #expect(Message.newestVisibleReply(in: replies, visible: visible) == Timestamp(seconds: 10))
    }
}
