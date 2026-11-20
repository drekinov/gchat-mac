import ChatModel
import ChatStore
import Foundation
import GoogleChat
import Synchronization

public struct Contact: Hashable, Sendable, Identifiable {
    public enum Source: Hashable, Sendable {
        case chats
        case directory
        /// Typed by the user; reached through the email alias.
        case email
    }

    public var user: UserName?
    public var displayName: String
    public var email: String?
    /// The DM with this person, if one is cached.
    public var directMessage: SpaceName?
    public var source: Source

    public var id: String { user?.rawValue ?? "email:\(email ?? displayName)" }

    public init(user: UserName?, displayName: String, email: String?, directMessage: SpaceName?, source: Source) {
        self.user = user
        self.displayName = displayName
        self.email = email
        self.directMessage = directMessage
        self.source = source
    }

    /// A contact for an address typed into the search field.
    public static func typed(email: String) -> Contact {
        Contact(user: nil, displayName: email, email: email, directMessage: nil, source: .email)
    }
}

/// People to start a DM with: members of cached chats (no extra permission) plus Workspace directory search when
/// the org allows it. Starting a DM reuses a cached one, otherwise `spaces.setup` returns or creates it.
public final class Contacts: Sendable {
    static let memberRefreshLimit = 30
    static let memberTTL = Duration.seconds(14 * 86_400)

    let api: any ChatAPI
    let directory: (any PeopleDirectoryAPI)?
    let engine: SyncEngine
    let store: any AccountStore
    let gate: SessionGate
    let me: UserName
    private let directoryOff = Mutex(false)

    init(
        api: any ChatAPI, directory: (any PeopleDirectoryAPI)?, engine: SyncEngine, store: any AccountStore,
        gate: SessionGate, me: UserName
    ) {
        self.api = api
        self.directory = directory
        self.engine = engine
        self.store = store
        self.gate = gate
        self.me = me
    }

    public var directoryAvailable: Bool { directory != nil && !directoryOff.withLock { $0 } }

    /// Everyone you share a cached chat with, ranked DM partners first, then by name.
    public func fromChats() throws(StoreError) -> [Contact] {
        var byUser: [UserName: Contact] = [:]
        for stored in try store.spaces() where !stored.isHidden {
            let others = try store.members(in: stored.space.name).filter {
                $0.member.name != me && $0.member.type == .human && !$0.member.isAnonymous && $0.state == .joined
            }
            for membership in others {
                let user = membership.member.name
                var contact =
                    byUser[user]
                    ?? Contact(
                        user: user, displayName: membership.member.displayName ?? "", email: nil, directMessage: nil,
                        source: .chats)
                if contact.displayName.isEmpty, let name = membership.member.displayName { contact.displayName = name }
                if stored.space.type == .directMessage, others.count == 1 { contact.directMessage = stored.space.name }
                byUser[user] = contact
            }
        }
        return byUser.values.filter { !$0.displayName.isEmpty }.sorted {
            if ($0.directMessage != nil) != ($1.directMessage != nil) { return $0.directMessage != nil }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Fills the member cache for chats that lack it (named spaces aren't fetched otherwise), a few at a time.
    public func refreshMembers(_ generation: Generation) async throws(SyncError) {
        let spaces = try engine.read { () throws(StoreError) in try store.spaces() }
        let stale = spaces.filter { !$0.isHidden && engine.needsMembers($0) }.prefix(Self.memberRefreshLimit)
        for stored in stale {
            try await engine.syncMemberTitle(stored.space.name, generation)
        }
    }

    /// Everyone in `space` as cached, including me, apps, invited people and deleted users, for the members list.
    /// Reads the cache only; `ensureMembers` refreshes it.
    public func memberships(in space: SpaceName) throws(StoreError) -> [Membership] {
        try store.members(in: space)
    }

    /// People who can be @-mentioned in `space`: its joined human members other than me, by name.
    public func mentionCandidates(in space: SpaceName) throws(StoreError) -> [Contact] {
        try store.members(in: space)
            .filter {
                $0.member.name != me && $0.member.type == .human && !$0.member.isAnonymous && $0.state == .joined
            }
            .compactMap { membership in
                guard let name = membership.member.displayName, !name.isEmpty else { return nil }
                return Contact(
                    user: membership.member.name, displayName: name, email: nil, directMessage: nil, source: .chats)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Fetches `space`'s members if the cache is missing or stale, so mentions can be offered.
    public func ensureMembers(in space: SpaceName, _ generation: Generation) async throws(SyncError) {
        guard let stored = try engine.read({ () throws(StoreError) in try store.space(space) }),
            engine.needsMembers(stored)
        else { return }
        try await engine.syncMemberTitle(space, generation)
    }

    /// Directory matches for `query`. Turns itself off after a 403 (scope not granted or admin policy).
    public func searchDirectory(_ query: String) async throws(SyncError) -> [Contact] {
        guard let directory, directoryAvailable else { return [] }
        let page: Page<DirectoryPerson>
        do throws(ChatAPIError) {
            page = try await directory.searchDirectory(query, pageToken: nil)
        } catch .permissionDenied, .unauthorized {
            directoryOff.withLock { $0 = true }
            return []
        } catch {
            throw .api(error, .searchDirectory)
        }
        return page.items.filter { $0.user != me }.map {
            Contact(user: $0.user, displayName: $0.displayName, email: $0.email, directMessage: nil, source: .directory)
        }
    }

    /// Opens the DM with `contact`: a cached one if known, otherwise from `spaces.setup`, merged and seeded.
    public func startDirectMessage(with contact: Contact, _ generation: Generation) async throws(SyncError)
        -> SpaceName
    {
        if let existing = contact.directMessage { return existing }
        if let user = contact.user, let cached = try cachedDirectMessage(with: user) { return cached }
        let member: DirectMessageMember
        if let user = contact.user {
            member = .user(user)
        } else if let email = contact.email {
            member = .email(email)
        } else {
            throw .api(
                .invalidArgument(GoogleErrorInfo(httpStatus: 0, status: "CLIENT_INVALID_MEMBER")), .setUpDirectMessage)
        }
        let space: Space
        do throws(ChatAPIError) {
            space = try await api.setUpDirectMessage(with: member)
        } catch {
            throw .api(error, .setUpDirectMessage)
        }
        try engine.commit(generation) { batch in
            batch.append(.mergeSpace(space))
            batch.append(.setSpaceHidden(space.name, false))
        }
        try? await engine.syncMessages(space.name, generation)
        try? await engine.syncMemberTitle(space.name, generation)
        return space.name
    }

    func cachedDirectMessage(with user: UserName) throws(SyncError) -> SpaceName? {
        let spaces = try engine.read { () throws(StoreError) in try store.spaces() }
        for stored in spaces where stored.space.type == .directMessage {
            let members = try engine.read { () throws(StoreError) in try store.members(in: stored.space.name) }
            let others = members.filter { $0.member.name != me }
            if others.count == 1, others[0].member.name == user { return stored.space.name }
        }
        return nil
    }
}

extension SyncEngine {
    /// Member lists exist for DMs and unnamed chats through titles; named spaces need them for contacts.
    func needsMembers(_ stored: StoredSpace) -> Bool {
        guard let fetched = stored.memberTitleFetched else { return true }
        return fetched.adding(Contacts.memberTTL) < clock.now()
    }
}
