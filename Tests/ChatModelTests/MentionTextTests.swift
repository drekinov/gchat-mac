import Foundation
import Testing

@testable import ChatModel

struct MentionTextTests {
    let ana = UserName(unchecked: "users/101")
    let bo = UserName(unchecked: "users/102")
    var names: [UserName: String] { [ana: "Ana Silva", bo: "Bo"] }

    @Test func replacesIntactTokensFromTheEnd() {
        let text = MentionText(
            visible: "hi @Ana Silva and @Bo!",
            mentions: [.init(range: 3..<13, user: ana), .init(range: 18..<21, user: bo)])
        #expect(text.wireText(displayNames: names) == "hi <users/101> and <users/102>!")
    }

    @Test func editedTokenStaysPlainText() {
        let text = MentionText(visible: "hi @Ana Silv", mentions: [.init(range: 3..<12, user: ana)])
        #expect(text.wireText(displayNames: names) == "hi @Ana Silv")
    }

    @Test func allMention() {
        let text = MentionText(visible: "@all ship it", mentions: [.init(range: 0..<4, user: .all)])
        #expect(text.wireText(displayNames: names) == "<users/all> ship it")
    }

    @Test func utf16OffsetsAfterEmoji() {
        let visible = "👍🏽 @Bo"
        let start = "👍🏽 ".utf16.count
        let text = MentionText(visible: visible, mentions: [.init(range: start..<(start + 3), user: bo)])
        #expect(text.wireText(displayNames: names) == "👍🏽 <users/102>")
    }

    @Test func outOfRangeMentionIsIgnored() {
        let text = MentionText(visible: "short", mentions: [.init(range: 3..<40, user: ana)])
        #expect(text.wireText(displayNames: names) == "short")
    }

    @Test func mentionsFromASentMessageKeepTheirTokenEvenWhenTheNameChanged() {
        let sender = User(name: UserName(unchecked: "users/1"))
        var message = Message(
            name: MessageName(unchecked: "spaces/A/messages/m"), sender: sender, createTime: Timestamp(seconds: 1),
            text: "👍🏽 @Bob Old and @Bo")
        let start = "👍🏽 ".utf16.count
        message.annotations = [
            Annotation(kind: .userMention(ana), startIndex: start, length: 8),
            Annotation(kind: .userMention(bo), startIndex: start + 13, length: 3),
            Annotation(kind: .richLink(URL(string: "https://x.example")!), startIndex: 0, length: 2),
        ]
        let mentions = MentionText.mentions(in: message)
        #expect(mentions.map(\.token) == ["@Bob Old", "@Bo"])
        let edited = MentionText(
            visible: "fixed " + message.text,
            mentions: mentions.map {
                MentionText.Mention(
                    range: ($0.range.lowerBound + 6)..<($0.range.upperBound + 6), user: $0.user, token: $0.token)
            })
        #expect(edited.wireText(displayNames: names) == "fixed 👍🏽 <users/101> and <users/102>")
    }

    @Test func twoTokensForOneUserBothSerialize() {
        let text = MentionText(
            visible: "@Old and @Ana Silva",
            mentions: [.init(range: 0..<4, user: ana, token: "@Old"), .init(range: 9..<19, user: ana)])
        #expect(text.wireText(displayNames: names) == "<users/101> and <users/101>")
    }
}
