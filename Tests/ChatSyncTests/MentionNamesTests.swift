import ChatModel
import Testing

@testable import ChatSync

@Suite struct MentionNamesTests {
    @Test func membersWinOverOtherChatsAndBlankNamesAreSkipped() {
        let alex = UserName(unchecked: "users/1")
        let sam = UserName(unchecked: "users/2")
        let kim = UserName(unchecked: "users/3")
        let members = [
            Membership(
                name: MembershipName(unchecked: "spaces/A/members/1"), member: User(name: alex, displayName: "Alex")),
            Membership(name: MembershipName(unchecked: "spaces/A/members/2"), member: User(name: sam, displayName: "")),
        ]
        let contacts = [
            Contact(user: alex, displayName: "Alex Elsewhere", email: nil, directMessage: nil, source: .chats),
            Contact(user: sam, displayName: "Sam", email: nil, directMessage: nil, source: .chats),
            Contact(user: kim, displayName: "", email: nil, directMessage: nil, source: .chats),
        ]
        #expect(Contacts.mentionNames(members: members, contacts: contacts) == [alex: "Alex", sam: "Sam"])
    }
}
