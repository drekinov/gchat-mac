import ChatModel
import ChatStore
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
    static func storedSpace(session: AccountSession, space: SpaceName) async -> StoredSpace? {
        (try? session.storedSpace(space)) ?? nil
    }

    @concurrent
    static func myRole(session: AccountSession, space: SpaceName) async -> Membership.Role? {
        session.myRole(in: space)
    }

    @concurrent
    static func memberships(session: AccountSession, space: SpaceName) async -> [Membership] {
        (try? session.contacts.memberships(in: space)) ?? []
    }

    /// FNV-1a over both names: the same pair always gives the same number, unlike `hashValue`.
    private static func seeded(_ space: SpaceName, _ user: UserName) -> UInt64 {
        (space.rawValue + "|" + user.rawValue).utf8.reduce(0xcbf2_9ce4_8422_2325) {
            ($0 ^ UInt64($1)) &* 0x100_0000_01b3
        }
    }

    /// Two other joined people per conversation, in an order seeded by its name so they stay the same across
    /// launches; a direct message gets its one other person. Any other conversation with fewer is left out.
    @concurrent
    static func faces(
        session: AccountSession, spaces: [SpaceName], direct: Set<SpaceName> = []
    ) async -> [SpaceName: [User]] {
        let me = session.me
        var faces: [SpaceName: [User]] = [:]
        for space in spaces {
            let people = ((try? session.contacts.memberships(in: space)) ?? [])
                .filter {
                    $0.state == .joined && $0.member.type == .human && !$0.member.isAnonymous && $0.member.name != me
                        && !($0.member.displayName ?? "").isEmpty
                }
                .map(\.member)
                .sorted { seeded(space, $0.name) < seeded(space, $1.name) }
            if people.count >= 2 {
                faces[space] = Array(people.prefix(2))
            } else if direct.contains(space), let one = people.first {
                faces[space] = [one]
            }
        }
        return faces
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
