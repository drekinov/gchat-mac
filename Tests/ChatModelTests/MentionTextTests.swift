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
}
