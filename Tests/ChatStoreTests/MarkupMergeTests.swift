import ChatModel
import Foundation
import Testing

@testable import ChatStore

@Suite struct MarkupMergeTests {
    private let mention = Annotation(kind: .userMention(UserName(unchecked: "users/2")), startIndex: 4, length: 4)

    private func plain(text: String = "hi @Bob", updated: Int64? = nil) -> Message {
        makeMessage(id: "m", at: 10, text: text, updated: updated)
    }

    private func formatted(_ markup: String = "*hi* <users/2>", text: String = "hi @Bob", updated: Int64? = nil)
        -> Message
    {
        var message = plain(text: text, updated: updated)
        message.formattedText = markup
        message.annotations = [mention]
        return message
    }

    private func stored(_ f: Fixture) throws -> Message {
        try #require(try f.store.message(messageName("A", "m")))
    }

    @Test(arguments: Backend.allCases)
    func sparseCopyFirstThenFullCopyBackfillsMarkupAndAnnotations(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(.upsertMessages([plain()]))
        try f.commit(.upsertMessages([formatted()]))
        let message = try stored(f)
        #expect(message.formattedText == "*hi* <users/2>")
        #expect(message.annotations == [mention])
    }

    @Test(arguments: Backend.allCases)
    func fullCopyFirstThenSparseCopyKeepsMarkup(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(.upsertMessages([formatted()]))
        try f.commit(.upsertMessages([plain()]))
        #expect(try stored(f) == formatted())
    }

    @Test(arguments: Backend.allCases)
    func equalCopyWithOtherTextNeverBackfills(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(.upsertMessages([plain()]))
        try f.commit(.upsertMessages([formatted("*other*", text: "other")]))
        #expect(try stored(f) == plain())
    }

    @Test(arguments: Backend.allCases)
    func newerVersionWithoutMarkupDropsTheOldMarkup(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(.upsertMessages([formatted()]))
        try f.commit(.upsertMessages([plain(text: "edited", updated: 20)]))
        let message = try stored(f)
        #expect(message.text == "edited")
        #expect(message.formattedText == nil)
    }

    @Test(arguments: Backend.allCases)
    func replaceStaysAuthoritativeButKeepsMarkupItLacks(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(.upsertMessages([formatted()]))
        try f.commit(.replaceMessages(spaceName("A"), [plain()], coveredBefore: stamp(100)))
        let kept = try stored(f)
        #expect(kept.formattedText == "*hi* <users/2>")
        #expect(kept.annotations.isEmpty)

        try f.commit(.replaceMessages(spaceName("A"), [formatted("_hi_ <users/2>")], coveredBefore: stamp(100)))
        #expect(try stored(f).formattedText == "_hi_ <users/2>")

        try f.commit(.replaceMessages(spaceName("A"), [plain(text: "refetched")], coveredBefore: stamp(100)))
        let replaced = try stored(f)
        #expect(replaced.text == "refetched")
        #expect(replaced.formattedText == nil)
    }

    @Test(arguments: Backend.allCases)
    func tombstonesNeverKeepMarkup(_ backend: Backend) throws {
        let f = try Fixture(backend)
        try f.commit(.upsertMessages([formatted()]))
        var tombstone = formatted(text: "", updated: 20)
        tombstone.deleteTime = stamp(20)
        try f.commit(.upsertMessages([tombstone]))
        #expect(try stored(f).formattedText == nil)

        try f.commit(.upsertMessages([formatted(updated: 30)]))
        let message = try stored(f)
        #expect(message.isDeleted)
        #expect(message.formattedText == nil)
    }

    @Test(arguments: Backend.allCases)
    func firstTombstoneArrivesWithoutMarkup(_ backend: Backend) throws {
        let f = try Fixture(backend)
        var tombstone = formatted(updated: 20)
        tombstone.deleteTime = stamp(20)
        try f.commit(.upsertMessages([tombstone]))
        #expect(try stored(f).formattedText == nil)
    }
}
