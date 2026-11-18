import ChatModel
import ChatSync
import Foundation

/// Store reads are synchronous; these entry points keep them off the main actor.
enum StoreReader {
    struct Loaded: Sendable {
        var messages: [Message]
        var outbox: [OutboxItem]
        var thread: [Message]
        var mine: [MessageName: [Emoji: ReactionName]]
    }

    @concurrent
    static func load(session: AccountSession, space: SpaceName, thread: ThreadName?) async -> Loaded {
        let messages = (try? session.messages(in: space, limit: 200)) ?? []
        let outbox = (try? session.outbox(in: space)) ?? []
        let threadMessages = thread.flatMap { try? session.messages(inThread: $0, limit: 200) } ?? []
        var mine: [MessageName: [Emoji: ReactionName]] = [:]
        for message in messages where !message.reactions.isEmpty {
            let own = session.reactions.mine(on: message.name)
            if !own.isEmpty { mine[message.name] = own }
        }
        return Loaded(messages: messages, outbox: outbox, thread: threadMessages, mine: mine)
    }

    @concurrent
    static func mentionCandidates(session: AccountSession, space: SpaceName) async -> [Contact] {
        (try? session.contacts.mentionCandidates(in: space)) ?? []
    }

    @concurrent
    static func contacts(session: AccountSession) async -> [Contact] {
        (try? session.contacts.fromChats()) ?? []
    }

    @concurrent
    static func directory(session: AccountSession, query: String) async -> [Contact] {
        (try? await session.contacts.searchDirectory(query)) ?? []
    }

    @concurrent
    static func startDirectMessage(session: AccountSession, contact: Contact) async -> Result<SpaceName, SyncError> {
        do throws(SyncError) {
            return .success(try await session.startDirectMessage(with: contact))
        } catch {
            return .failure(error)
        }
    }

    @concurrent
    static func draft(session: AccountSession, space: SpaceName, thread: ThreadName?) async -> String {
        (try? session.draft(space: space, thread: thread))?.text ?? ""
    }
}
