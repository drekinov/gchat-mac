import ChatModel
import ChatStore
import Foundation
import GoogleChat

/// Why an edit or delete didn't happen.
public enum MessageEditError: Error, Sendable, Equatable {
    /// The account isn't taking new network work (paused, signed out or backing off).
    case notAdmitted
    /// The message changed after editing started; carries the newest copy.
    case changedElsewhere(Message)
    /// The thread starter has replies, so deleting it needs `force`.
    case hasReplies
    /// Google refused: not the sender, or a manager in a space that doesn't allow it.
    case denied
    /// The message is gone.
    case gone
    case failed(SyncError)
}

/// A fresh copy of a message to edit.
public struct EditableCopy: Sendable, Equatable {
    public var message: Message
    /// Google holds formatting (links, bold, lists) the plain-text editor can't carry, so saving drops it.
    public var losesFormatting: Bool
}

extension AccountSession {
    /// Retries after a delete that wait out the event poll's trailing window and any running sync.
    static let deleteReconcileDelays: [Duration] = [.seconds(3), .seconds(10), .seconds(30)]

    /// The user's role in `space` while joined, from the cached member list; nil when unknown.
    public nonisolated func myRole(in space: SpaceName) -> Membership.Role? {
        let members = (try? contacts.memberships(in: space)) ?? []
        return members.first { $0.member.name == me && $0.state == .joined }?.role
    }

    /// Fetches the current copy of one of the user's messages and stores it.
    public func editableCopy(of name: MessageName) async throws(MessageEditError) -> EditableCopy {
        let generation = try admittedGeneration()
        let fetched: EditableMessage
        do {
            fetched = try await engine.api.getEditableMessage(name)
        } catch {
            throw failure(error, .readSpace, generation, space: name.space)
        }
        guard !fetched.message.isDeleted else { throw .gone }
        commitQuietly(name.space, generation) { $0.append(.upsertMessages([fetched.message])) }
        return EditableCopy(
            message: fetched.message,
            losesFormatting: Self.losesFormatting(fetched.message, formattedText: fetched.formattedText))
    }

    /// Replaces the text of one of the user's messages unless it changed after `basedOn`.
    public func editMessage(
        _ name: MessageName, text: String, basedOn: Timestamp
    ) async throws(MessageEditError) -> Message {
        var generation = try admittedGeneration()
        do { try await sends.pace(name.space) } catch { throw .failed(error) }
        let current: Message
        do {
            current = try await engine.api.getMessage(name)
        } catch {
            throw failure(error, .readSpace, generation, space: name.space)
        }
        guard !current.isDeleted else { throw .gone }
        let stored = try? store.message(name)
        if let newest = [current, stored].compactMap({ $0 }).max(by: { $0.version < $1.version }),
            newest.version > basedOn
        {
            throw .changedElsewhere(newest)
        }
        generation = try admittedGeneration()
        sends.markWrite(name.space)
        let updated: Message
        do {
            updated = try await engine.api.updateMessageText(name, text: text)
        } catch {
            throw failure(error, .updateMessage, generation, space: name.space)
        }
        commitQuietly(name.space, generation) { $0.append(.upsertMessages([updated])) }
        return (try? store.message(name)) ?? updated
    }

    /// Deletes a message; `force` also deletes a thread starter's replies. Google's tombstones arrive with the
    /// following event polls; until then the stored copies are marked deleted.
    public func deleteMessage(_ name: MessageName, force: Bool) async throws(MessageEditError) {
        var generation = try admittedGeneration()
        do { try await sends.pace(name.space) } catch { throw .failed(error) }
        generation = try admittedGeneration()
        sends.markWrite(name.space)
        do {
            try await engine.api.deleteMessage(name, force: force)
        } catch .notFound {
        } catch .failedPrecondition where !force {
            throw .hasReplies
        } catch {
            throw failure(error, .deleteMessage, generation, space: name.space)
        }
        let tombstones = localTombstones(for: name, force: force)
        commitQuietly(name.space, generation) { $0.append(.upsertMessages(tombstones)) }
        reconcileAfterDelete(name.space, generation)
    }

    private func admittedGeneration() throws(MessageEditError) -> Generation {
        guard let generation = gate.current else { throw .failed(.retired) }
        guard admitted else { throw .notAdmitted }
        return generation
    }

    private func failure(
        _ error: ChatAPIError, _ operation: ChatOperation, _ generation: Generation, space: SpaceName
    ) -> MessageEditError {
        switch error {
        case .permissionDenied: return .denied
        case .notFound: return .gone
        default:
            handle(.api(error, operation), generation, space: space)
            return .failed(.api(error, operation))
        }
    }

    /// A failed local write only delays what the next poll brings, so it isn't reported.
    private func commitQuietly(_ space: SpaceName, _ generation: Generation, _ build: (inout StoreWrite) -> Void) {
        try? store.write(gate: gate, generation: generation, build)
        didCommit(space, generation)
    }

    /// Stand-ins dated at the stored version, so Google's own tombstone, which is never older, replaces them.
    private func localTombstones(for name: MessageName, force: Bool) -> [Message] {
        guard let root = try? store.message(name), !root.isDeleted else { return [] }
        var targets = [root]
        if force, !root.isThreadReply, let thread = root.thread {
            let replies = (try? store.messages(inThread: thread, limit: 5000)) ?? []
            targets += replies.filter { $0.isThreadReply && !$0.isDeleted && $0.name != name }
        }
        return targets.map { message in
            var tombstone = message
            tombstone.deleteTime = message.version
            tombstone.text = ""
            tombstone.annotations = []
            tombstone.attachments = []
            tombstone.gifURLs = []
            tombstone.reactions = []
            tombstone.quoted = nil
            tombstone.cardsFallbackText = nil
            tombstone.cards = nil
            return tombstone
        }
    }

    private func reconcileAfterDelete(_ space: SpaceName, _ generation: Generation) {
        work.spawn { [weak self, clock] in
            for delay in Self.deleteReconcileDelays {
                do { try await clock.sleep(for: delay) } catch { return }
                guard let self, await self.reconcileDeleted(space, generation) else { continue }
                return
            }
        }
    }

    /// True once an event poll of `space` ran.
    private func reconcileDeleted(_ space: SpaceName, _ generation: Generation) async -> Bool {
        guard gate.isCurrent(generation), admitted else { return false }
        do {
            try await engine.syncEvents(space, generation)
            didCommit(space, generation)
            return true
        } catch {
            return false
        }
    }

    /// Compares the editor's plain text with Google's markup, ignoring mentions, which both carry.
    static func losesFormatting(_ message: Message, formattedText: String?) -> Bool {
        guard let formattedText else { return false }
        var plain = Array(message.text.utf16)
        let mentions = message.annotations.compactMap { annotation -> Range<Int>? in
            guard case .userMention = annotation.kind else { return nil }
            let range = annotation.startIndex..<(annotation.startIndex + annotation.length)
            return range.upperBound <= plain.count ? range : nil
        }
        for range in mentions.sorted(by: { $0.lowerBound > $1.lowerBound }) { plain.removeSubrange(range) }
        let marked = formattedText.replacing(/<users\/[^>]+>/, with: "")
        return String(decoding: plain, as: UTF16.self) != marked
    }
}
