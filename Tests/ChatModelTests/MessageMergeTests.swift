import ChatModel
import Foundation
import Testing

@Suite struct MessageMergeTests {
    private let sender = User(name: UserName(unchecked: "users/1"))

    private func message(_ text: String, markup: String? = nil, updated: Int64? = nil) -> Message {
        Message(
            name: MessageName(unchecked: "spaces/A/messages/m"), sender: sender,
            createTime: Timestamp(seconds: 10, nanos: 0),
            lastUpdateTime: updated.map { Timestamp(seconds: $0, nanos: 0) },
            text: text, formattedText: markup)
    }

    @Test func equalCopyWithMarkupBackfillsOnlyMarkupAndAnnotations() {
        var stored = message("hi")
        stored.reactions = [ReactionSummary(emoji: .unicode("👍"), count: 1)]
        var incoming = message("hi", markup: "*hi*")
        incoming.annotations = [Annotation(kind: .slashCommand, startIndex: 0, length: 2)]
        let merged = Message.merge(incoming, over: stored)
        #expect(merged?.formattedText == "*hi*")
        #expect(merged?.annotations == incoming.annotations)
        #expect(merged?.reactions == stored.reactions)
        #expect(Message.merge(incoming, over: merged) == nil)
    }

    @Test func equalCopyWithoutMarkupIsIgnored() {
        #expect(Message.merge(message("hi"), over: message("hi", markup: "*hi*")) == nil)
    }

    @Test func rewriteKeepsStoredMarkupOnlyForTheSameText() {
        let stored = message("hi", markup: "*hi*")
        #expect(Message.merge(message("hi"), over: stored, rewriteEqual: true)?.formattedText == "*hi*")
        #expect(Message.merge(message("bye"), over: stored, rewriteEqual: true)?.formattedText == nil)
        #expect(Message.merge(message("hi", markup: "_hi_"), over: stored, rewriteEqual: true)?.formattedText == "_hi_")
    }

    @Test func newerVersionBringsItsOwnMarkup() {
        let stored = message("hi", markup: "*hi*")
        #expect(Message.merge(message("hi", updated: 20), over: stored)?.formattedText == nil)
    }

    @Test func rowsStoredBeforeMarkupStillDecode() throws {
        var json =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(message("hi", markup: "*hi*")))
            as! [String: Any]
        json["formattedText"] = nil
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        #expect(decoded == message("hi"))
    }
}
