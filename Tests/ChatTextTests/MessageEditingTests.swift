import ChatModel
import ChatText
import Foundation
import Testing

private let alex = UserName(unchecked: "users/1")
private let sam = UserName(unchecked: "users/2")

private func message(
    _ text: String, markup: String?, mentions: [(UserName, Int, Int)] = [], updated: Int64? = nil
) -> Message {
    Message(
        name: MessageName(unchecked: "spaces/A/messages/m"), sender: User(name: alex),
        createTime: Timestamp(seconds: 10, nanos: 0), lastUpdateTime: updated.map { Timestamp(seconds: $0, nanos: 0) },
        text: text, formattedText: markup,
        annotations: mentions.map { Annotation(kind: .userMention($0.0), startIndex: $0.1, length: $0.2) })
}

@Suite struct EditLoaderTests {
    @Test func markupLoadsWithMentionsAsNames() {
        let loaded = EditableText(
            message(
                "Hi @Sam and @Alex, see doc", markup: "*Hi* <users/2> and <users/1>, see <https://example.com|doc>",
                mentions: [(alex, 12, 5), (sam, 3, 4)]))
        #expect(loaded.text == "*Hi* @Sam and @Alex, see <https://example.com|doc>")
        #expect(loaded.mentions.map(\.range) == [5..<9, 14..<19])
        #expect(loaded.mentions.map(\.user) == [sam, alex])
        #expect(!loaded.losesFormatting)
        #expect(loaded.original == "*Hi* <users/2> and <users/1>, see <https://example.com|doc>")
    }

    @Test func repeatedUsersMatchInOrder() {
        let loaded = EditableText(
            message("@Sam 🙂 @Sam", markup: "<users/2> 🙂 <users/2>", mentions: [(sam, 8, 4), (sam, 0, 4)]))
        #expect(loaded.text == "@Sam 🙂 @Sam")
        #expect(loaded.mentions.map(\.range) == [0..<4, 8..<12])
        #expect(loaded.original == "<users/2> 🙂 <users/2>")
    }

    @Test func allMayLackAnAnnotation() {
        let loaded = EditableText(message("@all *now*", markup: "<users/all> *now*"))
        #expect(loaded.text == "@all *now*")
        #expect(loaded.mentions.first?.user == .all)
        #expect(loaded.original == "<users/all> *now*")
    }

    @Test func tokensInsideCodeStayLiteral() {
        let loaded = EditableText(
            message("`<users/2>` @Sam", markup: "`<users/2>` <users/2>", mentions: [(sam, 12, 4)]))
        #expect(loaded.text == "`<users/2>` @Sam")
        #expect(loaded.mentions.map(\.range) == [12..<16])
    }

    @Test func unmatchedMentionsFallBackToPlainTextWithTheWarning() {
        for missing in [
            message("hi @Sam", markup: "*hi* <users/2>"),
            message("hi @Sam", markup: "*hi* <users/2>", mentions: [(alex, 3, 4)]),
            message("hi @Sam @Alex", markup: "*hi* <users/2> @Alex", mentions: [(sam, 3, 4), (alex, 8, 5)]),
        ] {
            let loaded = EditableText(missing)
            #expect(loaded.text == missing.text)
            #expect(loaded.losesFormatting)
        }
    }

    @Test func onlyWhatTheEditorCantCarryWarns() {
        #expect(EditableText(message("ship it :shipit:", markup: "ship *it* :shipit:")).losesFormatting)
        #expect(EditableText(message("see x", markup: "see <drive/x>")).losesFormatting)
        #expect(!EditableText(message("a < b > c", markup: "a < b > c")).losesFormatting)
        #expect(!EditableText(message("plain", markup: nil)).losesFormatting)
    }

    @Test func emojiLoadsUnchanged() {
        let loaded = EditableText(message("👩🏽‍💻 @Sam", markup: "_👩🏽‍💻_ <users/2>", mentions: [(sam, 8, 4)]))
        #expect(loaded.text == "_👩🏽‍💻_ @Sam")
        #expect(loaded.original == "_👩🏽‍💻_ <users/2>")
    }
}

@Suite struct RestoredDraftTests {
    @Test func aFailedSendsTextComesBackWithNames() {
        let restored = EditableText(
            wire: "*hi* <users/2> <users/all> <users/9> `<users/2>`", names: [sam: "Sam"])
        #expect(restored.text == "*hi* @Sam @all <users/9> `<users/2>`")
        #expect(restored.mentions.map(\.range) == [5..<9, 10..<14])
        #expect(restored.original == "*hi* <users/2> <users/all> <users/9> `<users/2>`")
    }
}

@Suite struct PendingEditTests {
    @Test func anUnchangedSaveSendsNothing() {
        var edit = PendingEdit(attempt: UUID(), message: MessageName(unchecked: "spaces/A/messages/m"))
        let loaded = edit.load(message("hi @Sam", markup: "*hi* <users/2>", mentions: [(sam, 3, 4)], updated: 20))
        #expect(edit.basedOn == Timestamp(seconds: 20, nanos: 0))
        let wire = MentionText(visible: loaded.text, mentions: loaded.mentions).wireText(displayNames: [:])
        #expect(edit.changes(wire) == nil)
        #expect(edit.changes(wire + "!") == "*hi* <users/2>!")
    }

    @Test func aConflictKeepsTheBaselineAndRebasesTheSave() {
        var edit = PendingEdit(attempt: UUID(), message: MessageName(unchecked: "spaces/A/messages/m"))
        _ = edit.load(message("v1", markup: "*v1*"))
        edit.saving = true
        edit.conflicted(with: message("v2", markup: "_v2_", updated: 30))
        #expect(!edit.saving)
        #expect(edit.basedOn == Timestamp(seconds: 30, nanos: 0))
        #expect(edit.original == "*v1*")
        #expect(edit.changes("*v1* edited") == "*v1* edited")
    }
}

@Suite struct OutboxNamingTests {
    private func mentions(_ document: ChatDocument) -> [String] {
        document.blocks.flatMap { block -> [Span] in
            switch block {
            case .paragraph(let spans), .quote(let spans): spans
            case .list(let items): items.flatMap(\.spans)
            case .code: []
            }
        }
        .filter { if case .mention = $0.kind { true } else { false } }
        .map(\.text)
    }

    @Test func pendingMentionsReadAsNames() {
        let document = ChatMarkup.parse("*hi* <users/1> <users/all>\n* <users/9> `<users/1>`")
            .namingMentions([alex: "Alex Doe"])
        #expect(mentions(document) == ["@Alex Doe", "@all", "@someone"])
        #expect(document.visibleText { _ in "?" } == "hi ? ?\n? `<users/1>`")
    }
}
