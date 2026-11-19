import AppKit
import ChatAuth
import ChatModel
import ChatNet
import ChatStore
import ChatSync
import Foundation
import GoogleChat
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case idle, starting, running, needsLogin
    }

    private(set) var phase: Phase = .idle
    private(set) var accounts: [AccountInfo] = []
    private(set) var snapshots: [AccountID: AccountSnapshot] = [:]
    var accountFilter: AccountID?
    private(set) var selection: SpaceKey?
    private(set) var loadedKey: SpaceKey?
    private(set) var openMessages: [Message] = []
    private(set) var openOutbox: [OutboxItem] = []
    private(set) var openMine: [MessageName: [Emoji: ReactionName]] = [:]
    private(set) var openThread: ThreadName?
    private(set) var threadMessages: [Message] = []
    private(set) var isLoading = false
    private(set) var sendError: String?
    var windowIsKey = true {
        didSet {
            guard windowIsKey != oldValue else { return }
            updateThreadReadPosition()
            if windowIsKey { markReadIfNeeded() }
        }
    }

    @ObservationIgnored private var sessions: [AccountID: AccountSession] = [:]
    @ObservationIgnored private(set) var world: FakeWorld?
    @ObservationIgnored private(set) var live: LiveAccounts?
    private var photoURLs: [AccountID: [UserName: URL]] = [:]
    private(set) var isSigningIn = false
    private(set) var signInError: String?
    private(set) var removingAccount: AccountID?
    private(set) var pendingRemoval: Set<AccountID> = []
    /// The Cloud project of the OAuth client the next sign-in uses.
    private(set) var savedClientProject: String?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var subscriptions: [AccountID: Task<Void, Never>] = [:]
    @ObservationIgnored private var recent: [(key: SpaceKey, messages: [Message])] = []
    @ObservationIgnored private var lastMarked: [SpaceKey: Timestamp] = [:]
    @ObservationIgnored private var visibleThreads: [ThreadName] = []
    @ObservationIgnored private var newestVisibleReply: Timestamp?
    @ObservationIgnored private var threadReadPosition: ThreadReadPosition?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var reloadQueued = false
    @ObservationIgnored private var focusTask: Task<Void, Never>?

    var showsSwitcher = false
    var showsMessageSearch = false
    private(set) var scrollCommand = ScrollCommand(sequence: 0, toTop: false)
    var preview: PreviewTarget?
    private(set) var composerAttachments: [ComposerID: [PendingAttachment]] = [:]
    private(set) var attachmentErrors: [ComposerID: String] = [:]
    /// Text and web links dropped on a conversation, waiting for that composer to type them in.
    private(set) var droppedText: [ComposerID: [String]] = [:]
    /// Bumped on every queued drop, so a second identical drop still reaches the composer.
    private(set) var droppedTextRevision = 0
    @ObservationIgnored var activeComposer: ComposerID?
    private(set) var openWindowRequest = 0
    var showsNewMessage = false
    private(set) var newMessageAccount: AccountID?
    private(set) var pendingComposerFocus: SpaceKey?

    var isFake: Bool { world != nil }

    // MARK: Boot

    static let defaultFakeAccounts = 3

    /// `--fake-accounts N` wins over the saved Developer setting; the result is clamped to 1...6.
    static func fakeAccountCount(arguments: [String], defaults: UserDefaults = .standard) -> Int {
        var count = defaults.object(forKey: "fakeAccountCount") as? Int ?? defaultFakeAccounts
        if let index = arguments.firstIndex(of: "--fake-accounts"), index + 1 < arguments.count,
            let value = Int(arguments[index + 1])
        {
            count = value
        }
        return min(max(count, 1), FakeScript.maxAccounts)
    }

    func boot(
        arguments: [String] = CommandLine.arguments, fakeTraffic: Bool = true, promptForNotifications: Bool = true
    ) async {
        guard phase == .idle else { return }
        phase = .starting
        AttachmentStaging.clearDrops()
        let bench = BenchConfig(arguments: arguments)
        guard arguments.contains("--fake") || bench != nil else {
            await bootLive(promptForNotifications: promptForNotifications)
            return
        }
        if promptForNotifications, bench == nil { await NotificationCenterPoster.requestOnFirstLaunch() }
        let world = await FakeWorld.build(
            accounts: bench?.accounts ?? Self.fakeAccountCount(arguments: arguments),
            traffic: bench?.traffic ?? fakeTraffic, trafficRange: bench.map { _ in 10...20 },
            notifications: NotificationCenterPoster(isFake: true),
            timing: bench == nil ? FakeWorld.timing() : SessionTiming())
        self.world = world
        for entry in world.entries { attach(entry.info, entry.session) }
        setAppActive(NSApplication.shared.isActive)
        phase = .running
    }

    private func bootLive(promptForNotifications: Bool) async {
        if promptForNotifications { await NotificationCenterPoster.requestOnFirstLaunch() }
        let live = LiveAccounts(
            root: LiveAccounts.defaultRoot(), notifications: NotificationCenterPoster(isFake: false))
        self.live = live
        AttachmentStaging.prune()
        savedClientProject = live.storedClient.map(Self.projectLabel)
        do {
            let report = try await live.manager.startup()
            if !report.failed.isEmpty { signInError = "\(report.failed.count) account(s) couldn't be restored." }
        } catch {
            signInError = "Couldn't restore accounts: \(Self.describe(error))"
        }
        for record in await live.manager.records {
            let info = liveInfo(record)
            accounts.append(info)
            if let session = await live.manager.session(record.id) { attach(info, session) }
        }
        setAppActive(NSApplication.shared.isActive)
        phase = accounts.isEmpty ? .needsLogin : .running
    }

    private func liveInfo(_ record: AccountRecord) -> AccountInfo {
        AccountInfo(
            id: record.id, name: Self.labels()[record.id.description] ?? record.email, colorIndex: accounts.count,
            me: record.me, email: record.email)
    }

    func startAddAccount(newClient: Bool = false) {
        guard signInTask == nil, removingAccount == nil else { return }
        signInTask = Task {
            await addAccount(newClient: newClient)
            signInTask = nil
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }

    /// Signs in through the browser. Asks for the Desktop OAuth client JSON the first time or when `newClient` is
    /// set (another org's project); the last one chosen is kept for later sign-ins.
    func addAccount(newClient: Bool = false) async {
        guard let live, !isSigningIn, removingAccount == nil else { return }
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        do {
            let saved = newClient ? nil : live.storedClient
            guard let client = try saved ?? chooseClientFile(live) else { return }
            let (record, session) = try await live.signIn(client: client)
            attach(liveInfo(record), session)
            setAppActive(NSApplication.shared.isActive)
            phase = .running
        } catch {
            if !Task.isCancelled { signInError = Self.describe(error) }
        }
    }

    func startReconnect(_ info: AccountInfo, newClient: Bool = false) {
        guard let live, signInTask == nil, removingAccount == nil, !pendingRemoval.contains(info.id) else { return }
        isSigningIn = true
        signInError = nil
        signInTask = Task {
            defer {
                isSigningIn = false
                signInTask = nil
            }
            do {
                let saved = newClient ? nil : try live.vault.load(info.id)?.client
                guard let client = try saved ?? chooseClientFile(live, saveAsDefault: false) else { return }
                let session = try await live.reconnect(info, client: client)
                detach(info.id)
                attach(info, session)
                setAppActive(NSApplication.shared.isActive)
                pushFocus()
                if selection?.account == info.id { requestReload() }
            } catch {
                if await live.manager.session(info.id) == nil {
                    if selection?.account == info.id { select(nil) }
                    detach(info.id)
                }
                if !Task.isCancelled { signInError = Self.describe(error) }
            }
        }
    }

    func removeAccount(_ id: AccountID) async {
        guard let live, removingAccount == nil, !isSigningIn, signInTask == nil else { return }
        removingAccount = id
        signInError = nil
        defer { removingAccount = nil }
        do {
            let report = try await live.manager.logout(id, refreshToken: nil)
            if selection?.account == id {
                select(nil)
                preview = nil
            }
            detach(id)
            showsMessageSearch = false
            if accountFilter == id { accountFilter = nil }
            if newMessageAccount == id {
                showsNewMessage = false
                newMessageAccount = nil
            }
            if activeComposer?.key.account == id { activeComposer = nil }
            if pendingComposerFocus?.account == id { pendingComposerFocus = nil }
            recent.removeAll { $0.key.account == id }
            composerAttachments = composerAttachments.filter { $0.key.key.account != id }
            attachmentErrors = attachmentErrors.filter { $0.key.key.account != id }
            droppedText = droppedText.filter { $0.key.key.account != id }
            guard report.failedSteps.isEmpty else {
                pendingRemoval.insert(id)
                signInError = "Local cleanup is incomplete. Retry removal or restart the app."
                return
            }
            pendingRemoval.remove(id)
            accounts.removeAll { $0.id == id }
            var labels = Self.labels()
            labels[id.description] = nil
            UserDefaults.standard.set(labels, forKey: Self.labelsKey)
            if accounts.isEmpty { phase = .needsLogin }
        } catch {
            signInError = "Couldn't start account removal. Try again."
        }
    }

    static let labelsKey = "accountLabels"

    static func labels(_ defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: labelsKey) as? [String: String] ?? [:]
    }

    /// An empty name restores the email.
    func rename(_ id: AccountID, to label: String) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        var labels = Self.labels()
        labels[id.description] = trimmed.isEmpty ? nil : trimmed
        UserDefaults.standard.set(labels, forKey: Self.labelsKey)
        accounts[index].name = labels[id.description] ?? accounts[index].email ?? accounts[index].name
    }

    func unreadCount(for account: AccountID) -> Int {
        snapshots[account]?.spaces.reduce(0) { $0 + $1.unreadCount } ?? 0
    }

    static func projectLabel(_ client: OAuthClientConfig) -> String {
        client.projectID ?? String(client.clientID.prefix { $0 != "-" })
    }

    private func chooseClientFile(_ live: LiveAccounts, saveAsDefault: Bool = true) throws -> OAuthClientConfig? {
        let panel = NSOpenPanel()
        panel.message = "Choose the Desktop OAuth client JSON from Google Cloud"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let data = try Data(contentsOf: url)
        guard saveAsDefault else { return try OAuthClientConfig(json: data) }
        let client = try live.importClient(data)
        savedClientProject = Self.projectLabel(client)
        return client
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case AuthError.cancelled, AuthError.timedOut: "Sign-in was cancelled or timed out."
        case AuthError.authorizationDenied(let code): "Google refused the sign-in (\(code))."
        case AuthError.insufficientScopes: "Some permissions were unticked. Sign in again and allow all of them."
        case AuthError.invalidClientConfig(let reason): "That file isn't a Desktop OAuth client (\(reason))."
        case AuthError.browserUnavailable: "Couldn't open the browser."
        case AuthError.tokenEndpoint(let status, let code): "Google's token endpoint refused (\(status) \(code ?? ""))."
        case LiveAccountError.alreadyAdded(let email): "\(email) is already added."
        case AuthError.wrongAccount: "Google returned a different account. Choose the account you’re reconnecting."
        case LiveAccountError.storeShredded: "This account's local data was erased; remove and add it again."
        default: "Sign-in failed: \(String(describing: error).prefix(120))"
        }
    }

    private func attach(_ info: AccountInfo, _ session: AccountSession) {
        if self.info(info.id) == nil { accounts.append(info) }
        sessions[info.id] = session
        subscriptions[info.id] = Task {
            for await snapshot in session.snapshots.values {
                guard !Task.isCancelled, sessions[info.id] === session else { return }
                ingest(snapshot)
            }
        }
    }

    private func detach(_ id: AccountID) {
        subscriptions.removeValue(forKey: id)?.cancel()
        sessions[id] = nil
        snapshots[id] = nil
        photoURLs[id] = nil
        lastMarked = lastMarked.filter { $0.key.account != id }
    }

    func scrollOpenSpace(toTop: Bool) {
        scrollCommand = ScrollCommand(sequence: scrollCommand.sequence + 1, toTop: toTop)
    }

    func mediaLoader(for account: AccountID) -> MediaLoader? {
        sessions[account]?.mediaLoader
    }

    /// Focus suppression of notifications only applies while the app is active.
    func setAppActive(_ active: Bool) {
        for session in sessions.values { Task { await session.setAppActive(active) } }
    }

    func openFromNotification(account: String, space: String) {
        guard let info = accounts.first(where: { $0.id.description == account }), let name = SpaceName(space) else {
            return
        }
        select(SpaceKey(account: info.id, space: name))
        NSApplication.shared.activate()
        openWindowRequest += 1
    }

    func shutdown() {
        for task in subscriptions.values { task.cancel() }
        world?.stop()
    }

    // MARK: Inbox

    func info(_ id: AccountID) -> AccountInfo? {
        accounts.first { $0.id == id }
    }

    var inbox: [InboxEntry] { entries(for: accountFilter) }

    var unreadTotal: Int { entries(for: nil).reduce(0) { $0 + $1.unread } }

    var recentUnread: [InboxEntry] { entries(for: nil).filter(\.hasUnread) }

    func entries(for account: AccountID?) -> [InboxEntry] {
        let epoch = Timestamp(seconds: 0)
        return snapshots.values
            .filter { account == nil || $0.account == account }
            .flatMap { snapshot in
                snapshot.spaces.map { InboxEntry(account: snapshot.account, summary: $0) }
            }
            .sorted { ($0.summary.lastActiveTime ?? epoch) > ($1.summary.lastActiveTime ?? epoch) }
    }

    func status(_ id: AccountID) -> AccountStatus {
        if pendingRemoval.contains(id) { return .failed("cleanup pending") }
        return snapshots[id]?.status ?? (sessions[id] == nil ? .failed("restore") : .starting)
    }

    func kind(of entry: InboxEntry) -> SpaceKind {
        switch entry.summary.type {
        case .space: .space
        case .groupChat: .group
        case .directMessage: entry.summary.isBotDM ? .bot : .directMessage
        }
    }

    func summary(for key: SpaceKey) -> SpaceSummary? {
        snapshots[key.account]?.spaces.first { $0.name == key.space }
    }

    func isThreaded(_ key: SpaceKey) -> Bool {
        summary(for: key)?.isThreaded ?? false
    }

    // MARK: Snapshots

    private func ingest(_ snapshot: AccountSnapshot) {
        BenchCounters.add { $0.snapshots += 1 }
        let id = snapshot.account
        let previous = snapshots[id]
        if let previous, snapshot.generation < previous.generation { return }
        snapshots[id] = snapshot

        guard let key = selection, key.account == id else { return }
        let skipped = previous.map { snapshot.revision > $0.revision + 1 } ?? false
        if snapshot.changedSpaces.contains(key.space) || skipped || !openOutbox.isEmpty { requestReload() }
    }

    // MARK: Selection

    func select(_ key: SpaceKey?) {
        guard key != selection else { return }
        if let old = selection, loadedKey == old {
            recent.removeAll { $0.key == old }
            recent.insert((old, openMessages), at: 0)
            recent = Array(recent.prefix(3))
        }
        selection = key
        openThread = nil
        newestVisibleReply = nil
        threadReadPosition = nil
        threadMessages = []
        openOutbox = []
        openMine = [:]
        visibleThreads = []
        sendError = nil
        if let key, let cached = recent.first(where: { $0.key == key }) {
            recent.removeAll { $0.key == key }
            openMessages = cached.messages
            loadedKey = key
        } else {
            openMessages = []
            loadedKey = nil
        }
        pushFocus()
        if key != nil { requestReload() }
    }

    func openThread(_ thread: ThreadName) {
        guard thread.space == selection?.space, openThread != thread else { return }
        openThread = thread
        newestVisibleReply = nil
        threadMessages = openMessages.filter { $0.thread == thread }
        updateThreadReadPosition()
        requestReload()
    }

    func closeThread() {
        openThread = nil
        newestVisibleReply = nil
        threadMessages = []
        updateThreadReadPosition()
    }

    private func pushFocus() {
        let focused = selection
        let threads = visibleThreads
        let position = threadReadPosition
        let sessions = sessions
        let previous = focusTask
        focusTask = Task {
            await previous?.value
            for (id, session) in sessions {
                let space = focused?.account == id ? focused?.space : nil
                await session.setFocus(
                    space, visibleThreads: space == nil ? [] : threads, threadRead: space == nil ? nil : position)
            }
        }
    }

    // MARK: Loading

    private func requestReload() {
        guard loadTask == nil else {
            reloadQueued = true
            return
        }
        isLoading = true
        loadTask = Task {
            repeat {
                reloadQueued = false
                await performLoad()
            } while reloadQueued
            isLoading = false
            loadTask = nil
        }
    }

    private func performLoad() async {
        BenchCounters.add { $0.reloads += 1 }
        guard let key = selection, let session = sessions[key.account] else { return }
        let thread = openThread
        let loaded = await StoreReader.load(session: session, space: key.space, thread: thread)
        guard selection == key, sessions[key.account] === session else { return }
        openMessages = loaded.messages
        loadPhotos(for: loaded.messages + loaded.thread, session: session)
        openOutbox = loaded.outbox
        openMine = loaded.mine
        loadedKey = key
        if openThread == thread {
            threadMessages = thread == nil ? [] : loaded.thread
        }
        updateVisibleThreads(key)
        markReadIfNeeded()
    }

    /// Profile photos for human senders not seen yet; the session caches misses, so repeats cost nothing.
    private func loadPhotos(for messages: [Message], session: AccountSession) {
        let cached = photoURLs[session.account] ?? [:]
        var users: [UserName] = cached[session.me] == nil ? [session.me] : []
        for message in messages where message.sender.type == .human && cached[message.sender.name] == nil {
            if !users.contains(message.sender.name) { users.append(message.sender.name) }
        }
        guard !users.isEmpty else { return }
        Task {
            let found = await session.photos.load(users)
            if !found.isEmpty, sessions[session.account] === session {
                photoURLs[session.account, default: [:]].merge(found) { $1 }
            }
        }
    }

    private func updateVisibleThreads(_ key: SpaceKey) {
        guard isThreaded(key) else { return }
        var seen = Set<ThreadName>()
        let withReplies = openMessages.reversed().compactMap { message -> ThreadName? in
            guard message.isThreadReply, let thread = message.thread, seen.insert(thread).inserted else { return nil }
            return thread
        }
        let next = Array(withReplies.prefix(10))
        guard next != visibleThreads else { return }
        visibleThreads = next
        pushFocus()
    }

    // MARK: Read state

    func threadViewportChanged(_ key: SpaceKey, thread: ThreadName, newest: Timestamp?) {
        guard key == selection, thread == openThread else { return }
        newestVisibleReply = newest
        updateThreadReadPosition()
    }

    private func updateThreadReadPosition() {
        let position: ThreadReadPosition?
        if windowIsKey, let thread = openThread, let newestVisibleReply {
            let previous = threadReadPosition.flatMap { $0.thread == thread ? $0.upTo : nil }
            position = ThreadReadPosition(thread: thread, upTo: max(previous ?? newestVisibleReply, newestVisibleReply))
        } else {
            position = nil
        }
        guard threadReadPosition != position else { return }
        threadReadPosition = position
        pushFocus()
    }

    private func markReadIfNeeded() {
        guard windowIsKey, let key = selection, loadedKey == key, let session = sessions[key.account],
            let newest = openMessages.map(\.createTime).max()
        else { return }
        if let marked = lastMarked[key], newest <= marked { return }
        lastMarked[key] = newest
        Task { await session.markRead(key.space, upTo: newest) }
    }

    // MARK: Composer

    func loadDraft(_ key: SpaceKey, thread: ThreadName?) async -> String {
        guard let session = sessions[key.account] else { return "" }
        return await StoreReader.draft(session: session, space: key.space, thread: thread)
    }

    func saveDraft(_ text: String, key: SpaceKey, thread: ThreadName?) async {
        guard let session = sessions[key.account] else { return }
        let draft = Draft(space: key.space, thread: thread, text: text, updated: Timestamp(Date()))
        try? await session.saveDraft(draft)
    }

    /// Sends through the session of `key` only; the composer's account never changes after it was created.
    @discardableResult
    func send(
        _ text: String, key: SpaceKey, thread: ThreadName?, attachments: [PendingAttachment] = []
    ) async -> Bool {
        guard let session = sessions[key.account] else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
        do {
            try await session.send(trimmed, in: key.space, thread: thread, attachments: attachments)
        } catch {
            sendError = "Could not queue the message."
            return false
        }
        sendError = nil
        if selection == key { requestReload() }
        return true
    }

    func repostAsNewMessage(_ item: OutboxItem, key: SpaceKey) async {
        guard let session = sessions[key.account] else { return }
        _ = try? await session.repostAsNewMessage(item)
        if selection == key { requestReload() }
    }

    // MARK: Mentions

    func prepareMentions(for key: SpaceKey) {
        guard let session = sessions[key.account] else { return }
        Task { await session.prepareMentions(in: key.space) }
    }

    func mentionCandidates(for key: SpaceKey) async -> [Contact] {
        guard let session = sessions[key.account] else { return [] }
        return await StoreReader.mentionCandidates(session: session, space: key.space)
    }

    // MARK: New message

    func searchMessages(_ query: String, account: AccountID, pageToken: String?) async throws(SyncError) -> Page<
        Message
    > {
        guard let session = sessions[account] else { throw .retired }
        let page = try await session.searchMessages(query, pageToken: pageToken)
        guard sessions[account] === session else { throw .retired }
        return page
    }

    func openSearchConversation(_ key: SpaceKey) {
        guard sessions[key.account] != nil else { return }
        showsMessageSearch = false
        if accountFilter != nil { accountFilter = key.account }
        select(key)
        closeThread()
    }

    func searchContext(around hit: Message, account: AccountID) async throws(SyncError) -> [Message] {
        guard let session = sessions[account] else { throw .retired }
        let messages = try await session.searchContext(around: hit)
        guard sessions[account] === session else { throw .retired }
        return messages
    }

    func openNewMessage() {
        guard !accounts.isEmpty else { return }
        newMessageAccount = accountFilter ?? accounts.first?.id
        showsNewMessage = true
    }

    func refreshContacts(for account: AccountID) {
        guard let session = sessions[account] else { return }
        Task { await session.refreshContacts() }
    }

    func contacts(for account: AccountID) async -> [Contact] {
        guard let session = sessions[account] else { return [] }
        return await StoreReader.contacts(session: session)
    }

    func directoryAvailable(for account: AccountID) -> Bool {
        sessions[account]?.contacts.directoryAvailable ?? false
    }

    func searchDirectory(_ query: String, for account: AccountID) async -> [Contact] {
        guard let session = sessions[account] else { return [] }
        return await StoreReader.directory(session: session, query: query)
    }

    /// Returns nil on success (the DM is then selected), otherwise a short message without server text.
    func startDirectMessage(_ contact: Contact, account: AccountID) async -> String? {
        guard let session = sessions[account] else { return "Couldn't start the chat: account unavailable." }
        switch await StoreReader.startDirectMessage(session: session, contact: contact) {
        case .success(let space):
            if let filter = accountFilter, filter != account { accountFilter = nil }
            let key = SpaceKey(account: account, space: space)
            pendingComposerFocus = key
            select(key)
            return nil
        case .failure(let error):
            return "Couldn't start the chat: \(Self.failureClass(error))."
        }
    }

    func consumeComposerFocus(_ key: SpaceKey) {
        if pendingComposerFocus == key { pendingComposerFocus = nil }
    }

    static func failureClass(_ error: SyncError) -> String {
        switch error {
        case .api(let api, _):
            switch api {
            case .permissionDenied, .failedPrecondition: "not allowed"
            case .notFound: "person not found"
            case .invalidArgument: "invalid address"
            case .rateLimited: "rate limited, try again shortly"
            case .transport: "network problem"
            case .unauthorized, .noCredentials: "sign-in needed"
            case .server, .otherHTTP: "server error"
            case .conflict, .decoding: "unexpected response"
            }
        case .store: "storage error"
        case .retired: "account closed"
        case .busy: "busy, try again"
        case .incompletePage: "incomplete data"
        }
    }

    // MARK: Attachments

    static let maxAttachmentsPerMessage = 10

    func attachments(for id: ComposerID) -> [PendingAttachment] { composerAttachments[id] ?? [] }

    func attachmentError(for id: ComposerID) -> String? { attachmentErrors[id] }

    func clearAttachmentError(_ id: ComposerID) { attachmentErrors[id] = nil }

    func removeAttachment(_ attachment: UUID, from id: ComposerID) {
        let removed = composerAttachments[id]?.first { $0.id == attachment }
        composerAttachments[id]?.removeAll { $0.id == attachment }
        if composerAttachments[id]?.isEmpty == true { composerAttachments[id] = nil }
        // A staged copy belongs to its chip alone (sending takes the chips, a failed send gives them back), so it
        // goes with the chip rather than waiting for the seven-day prune. User-selected originals aren't staged.
        if let removed {
            let staged = URL(fileURLWithPath: String(decoding: removed.bookmark, as: UTF8.self))
            if AttachmentStaging.contains(staged, for: id.key.account) {
                AttachmentStaging.removeStaged(staged, for: id.key.account)
            }
        }
    }

    func takeAttachments(_ id: ComposerID) -> [PendingAttachment] {
        let taken = composerAttachments[id] ?? []
        composerAttachments[id] = nil
        return taken
    }

    func restoreAttachments(_ attachments: [PendingAttachment], to id: ComposerID) {
        guard sessions[id.key.account]?.gate.current != nil, removingAccount != id.key.account else { return }
        composerAttachments[id] = attachments + (composerAttachments[id] ?? [])
    }

    /// Attaches the files among `drops` and passes web links and text on for the composer to type in. `false`
    /// refuses the drop.
    func addDroppedFiles(_ drops: [DroppedFile], to id: ComposerID) -> Bool {
        var candidates: [AttachCandidate] = []
        var texts: [String] = []
        var problems: [String] = []
        for drop in drops {
            switch drop {
            case .link(let url) where !url.isFileURL: texts.append(url.absoluteString)
            case .link(let url): candidates.append(.file(url))
            case .text(let text): texts.append(text)
            case .copy(let url): candidates.append(.dropped(url))
            case .tooLarge(let name): problems.append("\(RemoteText.title(name)) is larger than 200 MB.")
            case .unusable(let name): problems.append("\(RemoteText.title(name)) can't be attached.")
            }
        }
        // Not for an account that's gone or going: its composer won't be there to take them.
        let textQueued = !texts.isEmpty && sessions[id.key.account] != nil && removingAccount != id.key.account
        if textQueued {
            droppedText[id, default: []] += texts
            droppedTextRevision &+= 1
        }
        let attachable = canAttach(to: id)
        attach(candidates, to: id, problems: problems)
        return (attachable && !(candidates.isEmpty && problems.isEmpty)) || textQueued
    }

    /// The text and links dropped on this composer, handed over once, and only while it is on screen: a composer
    /// on its way out leaves them for the next time it shows.
    func takeDroppedText(_ id: ComposerID) -> [String] {
        guard selection == id.key, id.thread == nil || openThread == id.thread else { return [] }
        return droppedText.removeValue(forKey: id) ?? []
    }

    static let attachmentLimitProblem = "A message can have up to \(maxAttachmentsPerMessage) attachments."

    private func canAttach(to id: ComposerID) -> Bool {
        sessions[id.key.account]?.gate.current != nil && removingAccount != id.key.account
    }

    /// Bookmarks the files and queues them as chips; over-size files and failures become one inline message.
    func addFiles(_ urls: [URL], to id: ComposerID) {
        attach(urls.map(AttachCandidate.file), to: id, problems: [])
    }

    /// A file to attach, or a drop's scratch copy, which moves into staging only once it is next and fits.
    private enum AttachCandidate {
        case file(URL)
        case dropped(URL)
    }

    private struct AttachProblem: Error {
        let message: String
    }

    /// Queues the candidates in order, after any `earlier` problems. Only accepted files take a slot, and every drop
    /// copy that isn't attached is deleted, so nothing unattached stays on disk.
    private func attach(_ candidates: [AttachCandidate], to id: ComposerID, problems earlier: [String]) {
        guard canAttach(to: id) else {
            for case .dropped(let copy) in candidates { AttachmentStaging.discard(copy) }
            return
        }
        var problems = earlier
        var current = composerAttachments[id] ?? []
        for (index, candidate) in candidates.enumerated() {
            guard current.count < Self.maxAttachmentsPerMessage else {
                problems.append(Self.attachmentLimitProblem)
                for case .dropped(let copy) in candidates[index...] { AttachmentStaging.discard(copy) }
                break
            }
            let url: URL
            switch candidate {
            case .file(let file): url = file
            case .dropped(let copy): url = AttachmentStaging.adopt(copy, for: id.key.account)
            }
            switch Self.pendingAttachment(for: url, account: id.key.account) {
            case .success(let attachment):
                current.append(attachment)
            case .failure(let problem):
                problems.append(problem.message)
                if case .dropped = candidate { AttachmentStaging.removeStaged(url, for: id.key.account) }
            }
        }
        composerAttachments[id] = current.isEmpty ? nil : current
        var seen = Set<String>()
        let unique = problems.filter { seen.insert($0).inserted }
        attachmentErrors[id] = unique.isEmpty ? nil : unique.joined(separator: " ")
    }

    private static func pendingAttachment(
        for url: URL, account: AccountID
    ) -> Result<PendingAttachment, AttachProblem> {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentTypeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize else {
            return .failure(AttachProblem(message: "\(RemoteText.title(name)) can't be attached."))
        }
        guard size <= MediaLoader.maxFileBytes else {
            return .failure(AttachProblem(message: "\(RemoteText.title(name)) is larger than 200 MB."))
        }
        guard let bookmark = bookmark(for: url, account: account) else {
            return .failure(AttachProblem(message: "\(RemoteText.title(name)) couldn't be opened for attaching."))
        }
        let type =
            values?.contentType?.preferredMIMEType
            ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return .success(PendingAttachment(bookmark: bookmark, filename: name, contentType: type, byteCount: size))
    }

    /// A security-scoped bookmark when the sandbox grants one, otherwise a path to a staged copy.
    private static func bookmark(for url: URL, account: AccountID) -> Data? {
        if AttachmentStaging.contains(url, for: account) { return PathFileAccess.bookmark(for: url) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? SecurityScopedFileAccess.bookmark(for: url) { return data }
        return AttachmentStaging.stage(url, for: account).map(PathFileAccess.bookmark(for:))
    }

    /// Cmd-V with files or an image on the pasteboard attaches them instead of pasting text.
    func pasteIntoActiveComposer() -> Bool {
        guard let id = activeComposer, sessions[id.key.account]?.gate.current != nil, removingAccount != id.key.account
        else { return false }
        let pasteboard = NSPasteboard.general
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        if let files, !files.isEmpty {
            addFiles(files, to: id)
            return true
        }
        guard pasteboard.string(forType: .string) == nil, let image = NSImage(pasteboard: pasteboard),
            let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return false }
        guard let directory = AttachmentStaging.newFolder(for: id.key.account) else { return false }
        let stamp = Int(Date().timeIntervalSince1970)
        let file = directory.appending(path: "pasted-image-\(stamp)-\(UUID().uuidString.prefix(4)).png")
        guard (try? png.write(to: file)) != nil else { return false }
        addFiles([file], to: id)
        return true
    }

    // MARK: Reactions

    func customEmojis(for account: AccountID) -> [CustomEmoji] {
        sessions[account]?.reactions.customEmojis ?? []
    }

    func canReact(_ account: AccountID) -> Bool {
        switch status(account) {
        case .ok, .syncing: true
        case .starting, .offline, .backingOff, .needsLogin, .failed, .closing: false
        }
    }

    /// The emoji's reaction name if it is the account's own; custom emoji compare by resource name.
    func ownReaction(_ emoji: Emoji, on message: MessageName) -> ReactionName? {
        guard let own = openMine[message] else { return nil }
        if let direct = own[emoji] { return direct }
        guard case .custom(let name, _) = emoji else { return nil }
        for (key, value) in own {
            if case .custom(let other, _) = key, other == name { return value }
        }
        return nil
    }

    func messageContext(for key: SpaceKey) -> MessageContext {
        var context = MessageContext(me: info(key.account)?.me, messages: openMessages)
        context.actions = reactionActions(for: key)
        context.media = mediaLoader(for: key.account)
        context.openPreview = { [self] attachment in
            guard let media = mediaLoader(for: key.account) else { return }
            preview = PreviewTarget(attachment: attachment, media: media)
        }
        context.openGifPreview = { [self] url in
            guard let media = mediaLoader(for: key.account) else { return }
            preview = PreviewTarget(gifURL: url, media: media)
        }
        context.photoURL = { [self] in photoURLs[key.account]?[$0] }
        return context
    }

    func reactionActions(for key: SpaceKey) -> ReactionActions {
        ReactionActions(
            canReact: canReact(key.account),
            isMine: { [self] emoji, message in ownReaction(emoji, on: message) != nil },
            toggle: { [self] emoji, message in Task { await toggleReaction(emoji, on: message, key: key) } },
            customEmojis: { [self] in customEmojis(for: key.account) })
    }

    func toggleReaction(_ emoji: Emoji, on message: MessageName, key: SpaceKey) async {
        guard canReact(key.account), let session = sessions[key.account] else { return }
        await session.toggleReaction(emoji, on: message)
        if selection == key { requestReload() }
    }

    func discard(_ item: OutboxItem, key: SpaceKey) async {
        guard let session = sessions[key.account] else { return }
        try? await session.discard(item)
        if selection == key { requestReload() }
    }

    // MARK: Test support

    func waitUntilSettled(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if loadTask == nil { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
