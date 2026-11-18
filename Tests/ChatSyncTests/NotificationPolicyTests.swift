import ChatModel
import ChatStore
import Foundation
import Testing

@testable import ChatSync

struct PolicyCase: Sendable, CustomTestStringConvertible {
    enum Sender: Sendable { case other, me }
    enum Mention: Sendable { case none, me, everyone, someoneElse }

    static let me = UserName(unchecked: "users/1")
    static let other = UserName(unchecked: "users/2")
    static let spaceName = SpaceName(unchecked: "spaces/AAA")
    static let thread = ThreadName(unchecked: "spaces/AAA/threads/T1")
    static let otherThread = ThreadName(unchecked: "spaces/AAA/threads/T2")
    static let firstSync = Timestamp(seconds: 1_000)

    var name: String
    var type: SpaceType = .space
    var setting: SpaceNotificationSetting?
    var sender: Sender = .other
    var deleted = false
    var created = firstSync.adding(.seconds(10))
    var focused = false
    var appIsActive = true
    var firstSyncKnown = true
    var reply = false
    var participating = false
    var mention: Mention = .none
    var privateTo: UserName?
    var expected: Bool

    var testDescription: String { name }

    func evaluate() -> Bool {
        let annotations: [Annotation] =
            switch mention {
            case .none: []
            case .me: [Annotation(kind: .userMention(Self.me), startIndex: 0, length: 3)]
            case .everyone: [Annotation(kind: .userMention(.all), startIndex: 0, length: 4)]
            case .someoneElse: [Annotation(kind: .userMention(Self.other), startIndex: 0, length: 3)]
            }
        let threadName = reply ? Self.otherThread : Self.thread
        let message = Message(
            name: MessageName(unchecked: "spaces/AAA/messages/M1"),
            sender: User(name: sender == .me ? Self.me : Self.other), createTime: created,
            deleteTime: deleted ? created.adding(.seconds(1)) : nil, text: "hi", annotations: annotations,
            thread: threadName, isThreadReply: reply, privateViewer: privateTo)
        let stored = StoredSpace(
            space: Space(name: Self.spaceName, type: type), notificationSetting: setting)
        let context = PolicyContext(
            me: Self.me, focusedSpace: focused ? Self.spaceName : nil, appIsActive: appIsActive,
            firstSyncCompleted: firstSyncKnown ? Self.firstSync : nil,
            participatingThreads: participating ? [Self.otherThread] : [])
        return NotificationPolicy.shouldNotify(message, in: stored, context: context)
    }

    static func level(_ level: NotificationLevel, muted: Bool = false) -> SpaceNotificationSetting {
        SpaceNotificationSetting(level: level, isMuted: muted)
    }

    static let all: [PolicyCase] = [
        PolicyCase(name: "ALL: plain message", setting: level(.all), expected: true),
        PolicyCase(name: "ALL: reply in unrelated thread", setting: level(.all), reply: true, expected: true),
        PolicyCase(name: "ALL: DM", type: .directMessage, setting: level(.all), expected: true),
        PolicyCase(name: "ALL: own message", setting: level(.all), sender: .me, expected: false),
        PolicyCase(name: "ALL: deleted", setting: level(.all), deleted: true, expected: false),
        PolicyCase(
            name: "ALL: before first sync", setting: level(.all), created: firstSync.adding(.seconds(-1)),
            expected: false),
        PolicyCase(name: "ALL: at first sync", setting: level(.all), created: firstSync, expected: true),
        PolicyCase(name: "ALL: no first sync yet", setting: level(.all), firstSyncKnown: false, expected: false),
        PolicyCase(name: "ALL: focused and active", setting: level(.all), focused: true, expected: false),
        PolicyCase(
            name: "ALL: focused but app inactive", setting: level(.all), focused: true, appIsActive: false,
            expected: true),
        PolicyCase(name: "ALL: muted", setting: level(.all, muted: true), expected: false),
        PolicyCase(name: "ALL: private to someone else", setting: level(.all), privateTo: other, expected: false),
        PolicyCase(name: "ALL: private to me", setting: level(.all), privateTo: me, expected: true),
        PolicyCase(name: "OFF: plain", setting: level(.off), expected: false),
        PolicyCase(name: "OFF: mention", setting: level(.off), mention: .me, expected: false),
        PolicyCase(name: "OFF: DM", type: .directMessage, setting: level(.off), expected: false),
        PolicyCase(name: "muted: mention", setting: level(.forYou, muted: true), mention: .me, expected: false),
        PolicyCase(
            name: "muted: DM", type: .directMessage, setting: level(.all, muted: true), expected: false),
        PolicyCase(name: "MAIN: top-level", setting: level(.mainConversations), expected: true),
        PolicyCase(
            name: "MAIN: reply in other thread", setting: level(.mainConversations), reply: true, expected: false),
        PolicyCase(
            name: "MAIN: reply in participating thread", setting: level(.mainConversations), reply: true,
            participating: true, expected: true),
        PolicyCase(
            name: "MAIN: participating reply but focused", setting: level(.mainConversations), focused: true,
            reply: true, participating: true, expected: false),
        PolicyCase(
            name: "MAIN: participating reply but muted", setting: level(.mainConversations, muted: true), reply: true,
            participating: true, expected: false),
        PolicyCase(
            name: "MAIN: participating reply, own", setting: level(.mainConversations), sender: .me, reply: true,
            participating: true, expected: false),
        PolicyCase(
            name: "MAIN: participating reply, private to other", setting: level(.mainConversations), reply: true,
            participating: true, privateTo: other, expected: false),
        PolicyCase(name: "FOR_YOU: plain", setting: level(.forYou), expected: false),
        PolicyCase(name: "FOR_YOU: mention me", setting: level(.forYou), mention: .me, expected: true),
        PolicyCase(name: "FOR_YOU: mention all", setting: level(.forYou), mention: .everyone, expected: true),
        PolicyCase(
            name: "FOR_YOU: mention someone else", setting: level(.forYou), mention: .someoneElse, expected: false),
        PolicyCase(name: "FOR_YOU: DM plain", type: .directMessage, setting: level(.forYou), expected: true),
        PolicyCase(name: "FOR_YOU: group chat plain", type: .groupChat, setting: level(.forYou), expected: false),
        PolicyCase(
            name: "FOR_YOU: group chat mention", type: .groupChat, setting: level(.forYou), mention: .me,
            expected: true),
        PolicyCase(
            name: "FOR_YOU: reply mentioning me", setting: level(.forYou), reply: true, mention: .me, expected: true),
        PolicyCase(name: "FOR_YOU: own mention", setting: level(.forYou), sender: .me, mention: .me, expected: false),
        PolicyCase(
            name: "FOR_YOU: DM focused and active", type: .directMessage, setting: level(.forYou), focused: true,
            expected: false),
        PolicyCase(name: "nil setting: DM behaves like ALL", type: .directMessage, expected: true),
        PolicyCase(name: "nil setting: DM reply", type: .directMessage, reply: true, expected: true),
        PolicyCase(name: "nil setting: space top-level", expected: true),
        PolicyCase(name: "nil setting: space reply, not participating", reply: true, expected: false),
        PolicyCase(name: "nil setting: space reply, participating", reply: true, participating: true, expected: true),
        PolicyCase(name: "nil setting: group chat top-level", type: .groupChat, expected: true),
        PolicyCase(name: "nil setting: group chat reply", type: .groupChat, reply: true, expected: false),
    ]
}

struct NotificationPolicyTests {
    @Test(arguments: PolicyCase.all) func table(_ row: PolicyCase) {
        #expect(row.evaluate() == row.expected)
    }

    @Test func effectiveLevelDefaults() {
        func level(_ type: SpaceType, _ setting: SpaceNotificationSetting? = nil) -> NotificationLevel {
            NotificationPolicy.effectiveLevel(
                for: StoredSpace(space: Space(name: PolicyCase.spaceName, type: type), notificationSetting: setting))
        }
        #expect(level(.directMessage) == .all)
        #expect(level(.space) == .mainConversations)
        #expect(level(.groupChat) == .mainConversations)
        #expect(level(.space, SpaceNotificationSetting(level: .forYou, isMuted: false)) == .forYou)
    }
}
