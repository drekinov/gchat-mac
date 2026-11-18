import ChatModel
import Foundation
import Testing

@testable import ChatStore

enum Backend: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case sqlite
    case memory

    var testDescription: String { rawValue }
}

func spaceName(_ id: String) -> SpaceName { SpaceName(unchecked: "spaces/\(id)") }
func messageName(_ space: String, _ id: String) -> MessageName {
    MessageName(unchecked: "spaces/\(space)/messages/\(id)")
}
func threadName(_ space: String, _ id: String) -> ThreadName { ThreadName(unchecked: "spaces/\(space)/threads/\(id)") }
func stamp(_ seconds: Int64, _ nanos: Int32 = 0) -> Timestamp { Timestamp(seconds: seconds, nanos: nanos) }

let ann = User(name: UserName(unchecked: "users/1"), displayName: "Ann")

func makeMessage(
    _ space: String = "A", _ id: String, at created: Int64, nanos: Int32 = 0, text: String = "hello",
    updated: Int64? = nil, deleted: Int64? = nil, thread: String? = nil
) -> Message {
    Message(
        name: messageName(space, id), sender: ann, createTime: stamp(created, nanos),
        lastUpdateTime: updated.map { stamp($0) }, deleteTime: deleted.map { stamp($0) }, text: text,
        thread: thread.map { threadName(space, $0) }, isThreadReply: thread != nil)
}

func makeMessage(
    id: String, at created: Int64, nanos: Int32 = 0, text: String = "hello", updated: Int64? = nil,
    deleted: Int64? = nil, thread: String? = nil
) -> Message {
    makeMessage(
        "A", id, at: created, nanos: nanos, text: text, updated: updated, deleted: deleted, thread: thread)
}

func makeSpace(_ id: String = "A", name: String = "General") -> Space {
    Space(name: spaceName(id), type: .space, displayName: name, lastActiveTime: stamp(50), createTime: stamp(1))
}

func richMessage(canary: String = "rich") -> Message {
    Message(
        name: messageName("A", "rich"), sender: User(name: UserName(unchecked: "users/9"), displayName: canary),
        createTime: stamp(100, 123_456_789), lastUpdateTime: stamp(101, 5), deleteTime: nil, text: "text \(canary)",
        annotations: [
            Annotation(kind: .userMention(UserName(unchecked: "users/2")), startIndex: 0, length: 4),
            Annotation(kind: .richLink(URL(string: "https://example.com/\(canary)")!), startIndex: 5, length: 3),
            Annotation(
                kind: .customEmoji(CustomEmojiName(unchecked: "customEmojis/e1"), shortcode: canary), startIndex: 9,
                length: 1),
        ], thread: threadName("A", "t1"), isThreadReply: true,
        attachments: [
            Attachment(
                contentName: "file-\(canary).png", contentType: "image/png",
                source: .uploaded(MediaResourceName("media/\(canary)")!),
                thumbnailURI: URL(string: "https://example.com/t/\(canary)"),
                downloadURI: URL(string: "https://example.com/d/\(canary)")),
            Attachment(contentName: "drive-\(canary)", contentType: "x", source: .drive(fileID: canary)),
        ], gifURLs: [URL(string: "https://example.com/g/\(canary).gif")!],
        reactions: [
            ReactionSummary(emoji: .unicode("x\(canary)"), count: 2),
            ReactionSummary(emoji: .custom(CustomEmojiName(unchecked: "customEmojis/e1"), shortcode: canary), count: 1),
        ],
        quoted: QuotedMessage(
            name: messageName("A", "q"), lastUpdateTime: stamp(7), snapshotSender: UserName(unchecked: "users/3"),
            snapshotText: "quoted \(canary)"), cardsFallbackText: "card \(canary)",
        privateViewer: UserName(unchecked: "users/4"), clientMessageID: "client-\(canary)")
}

final class TempDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gchat-store-tests-\(UUID().uuidString)", isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

final class Fixture {
    let backend: Backend
    let temp = TempDirectory()
    let account = AccountID()
    let key: StoreKey
    let gate = SessionGate()
    var generation: Generation
    private(set) var store: any AccountStore

    var directory: AccountDirectory { AccountDirectory(root: temp.url, account: account) }

    init(_ backend: Backend) throws {
        self.backend = backend
        key = StoreKey.random(for: account)
        generation = gate.current!
        switch backend {
        case .sqlite:
            store = try SQLiteAccountStore.open(directory: AccountDirectory(root: temp.url, account: account), key: key)
        case .memory: store = InMemoryAccountStore()
        }
    }

    func reopenSQLite() throws {
        (store as? SQLiteAccountStore)?.close()
        store = try SQLiteAccountStore.open(directory: directory, key: key)
    }

    func closeSQLite() { (store as? SQLiteAccountStore)?.close() }

    func commit(_ operations: StoreWrite.Operation...) throws {
        try store.write(gate: gate, generation: generation) { batch in
            for operation in operations { batch.append(operation) }
        }
    }
}
