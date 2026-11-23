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
import os

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
    private(set) var openMessages: [Message] = [] {
        didSet { rowsRevision &+= 1 }
    }
    private(set) var openOutbox: [OutboxItem] = []
    private(set) var openMine: [MessageName: [Emoji: ReactionName]] = [:]
    private(set) var openThread: ThreadName?
    private(set) var threadMessages: [Message] = [] {
        didSet { rowsRevision &+= 1 }
    }
    /// Bumped whenever the loaded rows change, including a refreshed window with the same number of messages.
    private(set) var rowsRevision = 0
    private(set) var isLoading = false
    /// Messages older than the cached window, fetched on demand for the open space only.
    private(set) var history: [Message] = []
    private(set) var historyEnd = HistoryEnd.open
    private(set) var loadingHistory = false
    private(set) var sendError: String?
    /// An edit each composer was asked to start; the composer takes it and owns the edit from then on.
    private(set) var editRequests: [ComposerID: EditRequest] = [:]
    var pendingDelete: DeleteRequest?
    /// My role in the open space, for showing Delete on others' messages; Google decides in the end.
    private(set) var openRole: Membership.Role?
    @ObservationIgnored private var roleSource: RoleSource?
    @ObservationIgnored private var stashedDrafts: [ComposerID: StashedDraft] = [:]
    /// Deletes confirmed by Google this run; rows show as deleted until the store has Google's tombstones.
    @ObservationIgnored private var locallyDeleted: Set<MessageName> = []
    @ObservationIgnored private var deletedThreads: Set<ThreadName> = []
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
    @ObservationIgnored private var storeWindow: [Message] = []
    @ObservationIgnored private var historyOpening = UUID()
    @ObservationIgnored private var historyCursor: (before: Timestamp, token: String?)?

    enum HistoryEnd { case open, beginning, capped, failed }
    static let historyLimitKey = "historyLimit"
    static let historyLimits = [1000, 2000, 5000, 10000]

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
    @ObservationIgnored private var mentionRequests: [ComposerID: Contact] = [:]
    private(set) var mentionRequestRevision = 0
    @ObservationIgnored var activeComposer: ComposerID?
    private(set) var openWindowRequest = 0
    var showsNewMessage = false
    /// Whether the sidebar island is showing. View > Hide Sidebar and the island's own button change it.
    var showsSidebar = true
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
        failNextUnreadRead = arguments.contains("--fake-unread-failure")
        if promptForNotifications, bench == nil { await NotificationCenterPoster.requestOnFirstLaunch() }
        let world = await FakeWorld.build(
            accounts: bench?.accounts ?? Self.fakeAccountCount(arguments: arguments),
            traffic: bench?.traffic ?? fakeTraffic, trafficRange: bench.map { _ in 10...20 },
            notifications: notificationPoster(isFake: true),
            timing: bench == nil ? FakeWorld.timing() : SessionTiming())
        self.world = world
        for entry in world.entries { attach(entry.info, entry.session) }
        setAppActive(NSApplication.shared.isActive)
        phase = .running
    }

    private func bootLive(promptForNotifications: Bool) async {
        if promptForNotifications { await NotificationCenterPoster.requestOnFirstLaunch() }
        let live = LiveAccounts(
            root: LiveAccounts.defaultRoot(), notifications: notificationPoster(isFake: false))
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
        spaceFaces = spaceFaces.filter { $0.key.account != id }
        facesWarmed.remove(id)
        lastMarked = lastMarked.filter { $0.key.account != id }
    }

    func scrollOpenSpace(toTop: Bool) {
        pendingReveal = nil
        scrollCommand = ScrollCommand(sequence: scrollCommand.sequence + 1, toTop: toTop)
    }

    /// A message the open conversation should scroll to, from the image preview's Show in Chat.
    /// Bumped for each jump; the message list then looks at `pendingReveal(for:)`.
    private(set) var revealSequence = 0
    /// A jump waiting until its message is in the conversation's list: the list may still be loading, or showing an
    /// older cached window. It's delivered once the message is there, replaced by the next jump, dropped by a newer
    /// navigation (another conversation or thread, closing the thread, a scroll command), and given up after
    /// `revealPatience`.
    @ObservationIgnored private var pendingReveal: PendingReveal?
    static let revealPatience = Duration.seconds(10)

    struct PendingReveal: Equatable {
        let key: SpaceKey
        let message: MessageName
        /// The thread the message is a reply in; nil for a top-level message.
        let thread: ThreadName?
        let deadline: ContinuousClock.Instant
    }

    func pendingReveal(for key: SpaceKey) -> PendingReveal? {
        guard let pending = pendingReveal, pending.key == key else { return nil }
        guard ContinuousClock.now < pending.deadline else {
            pendingReveal = nil
            return nil
        }
        return pending
    }

    func revealDelivered(_ pending: PendingReveal) {
        if pendingReveal == pending { pendingReveal = nil }
    }

    /// The user went somewhere else, so a jump still waiting for its row no longer applies.
    func dropPendingReveal() {
        pendingReveal = nil
    }

    // MARK: Unread list

    enum UnreadListState {
        case loading
        case loaded(UnreadMessages)
        case failed
    }

    /// The conversation whose unread list is open. The model owns it, so the toolbar redrawing can't drop it.
    private(set) var unreadPopover: SpaceKey?
    private(set) var unreadState = UnreadListState.loading
    /// The badge count when the list opened, which sizes it while it stays open. Nil while thread read times were
    /// still due a check, because the count can grow: it then opens at full height.
    private(set) var unreadSizedFor: Int?
    /// Whether the list shown was read while some of its threads' read times were still due a check.
    private(set) var unreadReadWhileDiscovering = false
    @ObservationIgnored private var unreadLoad: Task<Void, Never>?
    @ObservationIgnored private var unreadSequence = 0
    /// `--fake-unread-failure`: the first read fails, so Try Again can be checked by hand.
    @ObservationIgnored private var failNextUnreadRead = false
    private static let unreadLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Thimble", category: "unread")

    func toggleUnread(_ key: SpaceKey) {
        if unreadPopover == key { closeUnread() } else { openUnread(key) }
    }

    func openUnread(_ key: SpaceKey) {
        unreadPopover = key
        unreadState = .loading
        unreadReadWhileDiscovering = false
        unreadSizedFor = isDiscovering(key) ? nil : summary(for: key)?.unreadCount ?? 0
        reloadUnread()
    }

    func closeUnread() {
        unreadLoad?.cancel()
        unreadLoad = nil
        unreadSequence += 1
        unreadPopover = nil
        unreadState = .loading
    }

    func retryUnread() {
        unreadState = .loading
        reloadUnread()
    }

    /// Whether the list may still grow: it was read, or its room still is, with thread read times due a check.
    var unreadIsUpdating: Bool {
        guard let key = unreadPopover else { return false }
        return unreadReadWhileDiscovering || isDiscovering(key)
    }

    private func isDiscovering(_ key: SpaceKey) -> Bool {
        snapshots[key.account]?.discoveringSpaces.contains(key.space) ?? false
    }

    /// Reads the open list again. Only the newest read for the same opening and the same session lands; a failed
    /// refresh keeps the list already shown.
    private func reloadUnread() {
        guard let key = unreadPopover else { return }
        unreadLoad?.cancel()
        unreadSequence += 1
        let sequence = unreadSequence
        guard let session = sessions[key.account] else {
            Self.unreadLog.error("Unread list read failed: no session for the account")
            unreadState = .failed
            return
        }
        let discovering = isDiscovering(key)
        let injectFailure = failNextUnreadRead
        failNextUnreadRead = false
        unreadLoad = Task {
            let result =
                injectFailure
                ? .failure(.store(.sqlite(code: 1))) : await StoreReader.unread(session: session, space: key.space)
            guard !Task.isCancelled, sequence == unreadSequence, unreadPopover == key, sessions[key.account] === session
            else { return }
            unreadLoad = nil
            switch result {
            case .success(let list):
                unreadState = .loaded(list)
                unreadReadWhileDiscovering = discovering
            case .failure(let error):
                Self.unreadLog.error("Unread list read failed: \(Self.describe(error), privacy: .public)")
                if case .loaded = unreadState { return }
                unreadState = .failed
            }
        }
    }

    /// The failure's kind and code only, never content.
    private static func describe(_ error: SyncError) -> String {
        switch error {
        case .store(.sqlite(let code)): "sqlite \(code)"
        case .store(.crypto(let crypto)): "crypto \(crypto)"
        case .store(let store): "store \(store)"
        default: "\(error)"
        }
    }

    /// Scrolls the open conversation to a message from the unread list, opening its thread first when it's a reply.
    func reveal(_ message: Message) {
        reveal(message.name, inThread: message.isThreadReply ? message.thread : nil)
    }

    /// Only a conversation that shows threads opens one for a reply; elsewhere replies are rows in the main list.
    private func threadToOpen(_ thread: ThreadName?) -> ThreadName? {
        guard let thread, let key = selection, isThreaded(key) else { return nil }
        return thread
    }

    /// Closes the preview and scrolls to `message`, opening its thread first when it's a reply.
    func showInConversation(_ message: MessageName) {
        preview = nil
        let loaded = openMessages.first { $0.name == message } ?? threadMessages.first { $0.name == message }
        reveal(message, inThread: loaded?.isThreadReply == true ? loaded?.thread : nil)
    }

    private func reveal(_ message: MessageName, inThread reply: ThreadName?) {
        guard let key = selection else { return }
        let thread = threadToOpen(reply)
        if let thread { openThread(thread) }
        pendingReveal = PendingReveal(
            key: key, message: message, thread: thread, deadline: .now + Self.revealPatience)
        revealSequence += 1
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
        warmFaces(id)
        refreshChangedFaces(snapshot, previous: previous)

        let skipped = previous.map { snapshot.revision > $0.revision + 1 } ?? false
        if let open = unreadPopover, open.account == id {
            let wasDiscovering = previous?.discoveringSpaces.contains(open.space) ?? false
            if snapshot.changedSpaces.contains(open.space) || skipped || previous?.generation != snapshot.generation
                || wasDiscovering != snapshot.discoveringSpaces.contains(open.space)
            {
                reloadUnread()
            }
        }
        guard let key = selection, key.account == id else { return }
        if snapshot.changedSpaces.contains(key.space) || skipped || !openOutbox.isEmpty { requestReload() }
    }

    // MARK: Sidebar faces

    /// Two other members of each space and group chat, for the sidebar's overlapping faces.
    private(set) var spaceFaces: [SpaceKey: [User]] = [:]
    @ObservationIgnored private var facesWarmed: Set<AccountID> = []

    func photoURL(_ user: UserName, account: AccountID) -> URL? { photoURLs[account]?[user] }

    /// Once per account: shows the faces already cached, fills the cache for spaces in the background (newest first,
    /// one at a time, skipping lists younger than the cache's two weeks), then shows the rest.
    private func warmFaces(_ account: AccountID) {
        guard !facesWarmed.contains(account), let session = sessions[account], let snapshot = snapshots[account],
            !snapshot.spaces.isEmpty
        else { return }
        facesWarmed.insert(account)
        let epoch = Timestamp(seconds: 0)
        let recent = snapshot.spaces.sorted { ($0.lastActiveTime ?? epoch) > ($1.lastActiveTime ?? epoch) }
        let shown = recent.filter { $0.type != .directMessage || !$0.isBotDM }.map(\.name)
        let spaces = recent.filter { $0.type == .space }.map(\.name)
        let direct = Set(recent.filter { $0.type == .directMessage }.map(\.name))
        Task {
            await refreshFaces(account, session: session, spaces: shown, direct: direct)
            await session.prepareMembers(in: spaces)
            await refreshFaces(account, session: session, spaces: shown, direct: direct)
        }
    }

    /// Spaces and group chats whose members were refetched since the last snapshot, such as one just opened.
    private func refreshChangedFaces(_ snapshot: AccountSnapshot, previous: AccountSnapshot?) {
        guard let previous, facesWarmed.contains(snapshot.account), let session = sessions[snapshot.account] else {
            return
        }
        // A skipped revision means snapshots were coalesced, so `changedSpaces` no longer names every change.
        let skipped = snapshot.revision > previous.revision + 1
        guard skipped || !snapshot.changedSpaces.isEmpty else { return }
        let changed = snapshot.spaces.filter { summary in
            (skipped || snapshot.changedSpaces.contains(summary.name))
                && (summary.type != .directMessage || !summary.isBotDM)
                && summary.membersFetched != nil
                && previous.spaces.first { $0.name == summary.name }?.membersFetched != summary.membersFetched
        }
        guard !changed.isEmpty else { return }
        let direct = Set(changed.filter { $0.type == .directMessage }.map(\.name))
        Task { await refreshFaces(snapshot.account, session: session, spaces: changed.map(\.name), direct: direct) }
    }

    private func refreshFaces(
        _ account: AccountID, session: AccountSession, spaces: [SpaceName], direct: Set<SpaceName> = []
    ) async {
        let found = await StoreReader.faces(session: session, spaces: spaces, direct: direct)
        guard sessions[account] === session else { return }
        for space in spaces { spaceFaces[SpaceKey(account: account, space: space)] = found[space] }
        let cached = photoURLs[account] ?? [:]
        var missing: [UserName] = []
        for user in found.values.joined() where cached[user.name] == nil && !missing.contains(user.name) {
            missing.append(user.name)
        }
        guard !missing.isEmpty else { return }
        let photos = await session.photos.load(missing)
        if !photos.isEmpty, sessions[account] === session {
            photoURLs[account, default: [:]].merge(photos) { $1 }
        }
    }

    // MARK: Selection

    func select(_ key: SpaceKey?) {
        guard key != selection else { return }
        if let old = selection, loadedKey == old {
            recent.removeAll { $0.key == old }
            recent.insert((old, storeWindow), at: 0)
            recent = Array(recent.prefix(3))
        }
        selection = key
        pendingReveal = nil
        if unreadPopover != nil, unreadPopover != key { closeUnread() }
        endEdits { $0.key != key }
        pendingDelete = nil
        openRole = nil
        roleSource = nil
        openThread = nil
        newestVisibleReply = nil
        threadReadPosition = nil
        threadMessages = []
        openOutbox = []
        openMine = [:]
        visibleThreads = []
        sendError = nil
        history = []
        historyEnd = .open
        loadingHistory = false
        historyCursor = nil
        historyOpening = UUID()
        if let key, let cached = recent.first(where: { $0.key == key }) {
            recent.removeAll { $0.key == key }
            openMessages = cached.messages
            loadedKey = key
        } else {
            openMessages = []
            loadedKey = nil
        }
        storeWindow = openMessages
        pushFocus()
        if key != nil { requestReload() }
    }

    func openThread(_ thread: ThreadName) {
        guard thread.space == selection?.space, openThread != thread else { return }
        if pendingReveal?.thread != thread { pendingReveal = nil }
        if let old = openThread { endEdits { $0.thread == old } }
        openThread = thread
        newestVisibleReply = nil
        threadMessages = openMessages.filter { $0.thread == thread }
        updateThreadReadPosition()
        requestReload()
    }

    func closeThread() {
        pendingReveal = nil
        if let old = openThread { endEdits { $0.thread == old } }
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
        if historyCursor != nil, let oldest = loaded.messages.first?.createTime {
            keepInHistory(openMessages.filter { $0.createTime < oldest })
        }
        storeWindow = loaded.messages
        openMessages = withLocalDeletes(withHistory(loaded.messages))
        loadPhotos(for: loaded.messages + loaded.thread, session: session)
        openOutbox = loaded.outbox
        openMine = loaded.mine
        loadedKey = key
        if openThread == thread {
            threadMessages = withLocalDeletes(
                thread.map { thread in Self.merged(history.filter { $0.thread == thread }, loaded.thread) } ?? [])
        }
        updateVisibleThreads(key)
        markReadIfNeeded()
        let source = RoleSource(key: key, fetched: summary(for: key)?.membersFetched)
        if roleSource != source {
            roleSource = source
            let role = await StoreReader.myRole(session: session, space: key.space)
            if selection == key { openRole = role }
        }
    }

    // MARK: Older history

    /// Fetches up to five pages older than what's shown, stopping once one adds a visible row.
    func loadOlder() {
        guard let key = selection, loadedKey == key, !loadingHistory, historyEnd == .open,
            let session = sessions[key.account]
        else { return }
        if historyCursor == nil {
            guard let oldest = openMessages.first?.createTime else {
                historyEnd = .beginning
                return
            }
            historyCursor = (oldest.adding(.microseconds(1)), nil)
        }
        let opening = historyOpening
        let threaded = isThreaded(key)
        let limit = UserDefaults.standard.integer(forKey: Self.historyLimitKey)
        loadingHistory = true
        Task {
            var end = HistoryEnd.open
            for _ in 0..<5 {
                guard let cursor = historyCursor else { break }
                let page: Page<Message>
                do {
                    page = try await session.olderMessages(
                        in: key.space, before: cursor.before, pageToken: cursor.token)
                } catch {
                    end = .failed
                    break
                }
                guard historyOpening == opening else { return }
                keepInHistory(page.items)
                openMessages = withLocalDeletes(withHistory(storeWindow))
                if let thread = openThread {
                    threadMessages = withLocalDeletes(
                        Self.merged(page.items.filter { $0.thread == thread }, threadMessages))
                }
                loadPhotos(for: page.items, session: session)
                historyCursor = (cursor.before, page.nextPageToken)
                if page.nextPageToken == nil {
                    end = .beginning
                    break
                }
                if history.count >= (limit > 0 ? limit : 2000) {
                    end = .capped
                    break
                }
                if page.items.contains(where: { !threaded || !$0.isThreadReply }) { break }
            }
            guard historyOpening == opening else { return }
            historyEnd = end
            loadingHistory = false
        }
    }

    func retryHistory() {
        guard historyEnd == .failed else { return }
        historyEnd = .open
        loadOlder()
    }

    private func keepInHistory(_ messages: [Message]) {
        guard !messages.isEmpty else { return }
        history = Self.merged(history, messages)
    }

    private func withHistory(_ window: [Message]) -> [Message] {
        history.isEmpty ? window : Self.merged(history, window)
    }

    /// Union by name, ordered by creation time. The later list wins unless its copy is older or would undo a
    /// delete (`Message.merge`).
    static func merged(_ older: [Message], _ newer: [Message]) -> [Message] {
        var byName = Dictionary(older.map { ($0.name, $0) }) { _, last in last }
        for message in newer {
            let current = byName[message.name]
            byName[message.name] = Message.merge(message, over: current, rewriteEqual: true) ?? current
        }
        return byName.values.sorted { ($0.createTime, $0.name.rawValue) < ($1.createTime, $1.name.rawValue) }
    }

    /// Profile photos for `users` not seen yet, for lists of people outside a conversation.
    func loadPhotos(for users: [UserName], account: AccountID) {
        guard let session = sessions[account] else { return }
        let cached = photoURLs[account] ?? [:]
        let missing = users.filter { cached[$0] == nil }
        guard !missing.isEmpty else { return }
        Task {
            let found = await session.photos.load(missing)
            if !found.isEmpty, sessions[account] === session { photoURLs[account, default: [:]].merge(found) { $1 } }
        }
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

    /// The open thread's read position only rises, and only from replies on screen while the window is key; an
    /// empty viewport or losing focus keeps what was already seen.
    private func updateThreadReadPosition() {
        var position = threadReadPosition.flatMap { $0.thread == openThread ? $0 : nil }
        if windowIsKey, let thread = openThread, let newestVisibleReply {
            position = ThreadReadPosition(
                thread: thread, upTo: max(position?.upTo ?? newestVisibleReply, newestVisibleReply))
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

    /// The conversation's stored record, for its details: when it was made, guests, notifications.
    func storedSpace(for key: SpaceKey) async -> StoredSpace? {
        guard let session = sessions[key.account] else { return nil }
        return await StoreReader.storedSpace(session: session, space: key.space)
    }

    /// The space's cached memberships, for the members list. `ensureMembers` refreshes a stale cache.
    func memberships(for key: SpaceKey) async -> [Membership] {
        guard let session = sessions[key.account] else { return [] }
        return await StoreReader.memberships(session: session, space: key.space)
    }

    /// Fetches the space's members when the cache is missing or stale; false when they couldn't be fetched now.
    func ensureMembers(for key: SpaceKey) async -> Bool {
        guard let session = sessions[key.account] else { return false }
        return await session.ensureMembers(in: key.space)
    }

    /// Asks a composer to insert an @-mention, for the members list's Mention button.
    func requestMention(_ contact: Contact, in id: ComposerID) {
        mentionRequests[id] = contact
        mentionRequestRevision += 1
    }

    func takeMentionRequest(_ id: ComposerID) -> Contact? {
        mentionRequests.removeValue(forKey: id)
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
        // The thread's messages come second: a reply loaded only for the open thread isn't in the conversation's.
        context.openPreview = { [self] attachment in
            guard let media = mediaLoader(for: key.account) else { return }
            preview = PreviewTarget(
                attachment: attachment, media: media, messages: [openMessages, threadMessages], space: summary(for: key)
            )
        }
        context.openGifPreview = { [self] url in
            guard let media = mediaLoader(for: key.account) else { return }
            preview = PreviewTarget(
                gifURL: url, media: media, messages: [openMessages, threadMessages], space: summary(for: key))
        }
        context.photoURL = { [self] in photoURLs[key.account]?[$0] }
        return context
    }

    func reactionActions(for key: SpaceKey) -> ReactionActions {
        ReactionActions(
            canReact: canReact(key.account),
            isMine: { [self] emoji, message in ownReaction(emoji, on: message) != nil },
            toggle: { [self] emoji, message in Task { await toggleReaction(emoji, on: message, key: key) } },
            customEmojis: { [self] in customEmojis(for: key.account) },
            reactors: { [self] message, summaries in await reactors(on: message, key: key, summaries: summaries) },
            media: mediaLoader(for: key.account),
            canEdit: { [self] in canEdit($0, key: key) },
            canDelete: { [self] in canDelete($0, key: key) },
            edit: { [self] in beginEdit($0, key: key) },
            delete: { [self] in requestDelete($0, key: key, replies: $1) },
            editing: Set(editRequests.filter { $0.key.key == key }.values.map(\.message)))
    }

    /// Everyone who reacted to a message, by emoji: you first, then in the order Google lists them, each person
    /// once. Names come from the conversation's members, then from the senders loaded in it.
    func reactors(on message: MessageName, key: SpaceKey, summaries: [ReactionSummary]) async -> [Emoji: [Reactor]]? {
        guard let session = sessions[key.account],
            let list = await session.reactors(on: message, matching: summaries)
        else { return nil }
        let members = await StoreReader.memberships(session: session, space: key.space)
        var names: [UserName: String] = [:]
        for membership in members {
            if let name = membership.member.displayName, !name.isEmpty { names[membership.member.name] = name }
        }
        names.merge(list.names) { known, _ in known }
        if list.users.values.joined().contains(where: { names[$0] == nil }) {
            for contact in await StoreReader.contacts(session: session) {
                guard let user = contact.user, names[user] == nil, !contact.displayName.isEmpty else { continue }
                names[user] = contact.displayName
            }
        }
        for sent in openMessages + threadMessages where names[sent.sender.name] == nil {
            if let name = sent.sender.displayName, !name.isEmpty { names[sent.sender.name] = name }
        }
        let users = list.users
        let me = info(key.account)?.me
        let photos = photoURLs[key.account] ?? [:]
        return users.mapValues { list in
            var seen = Set<UserName>()
            let unique = list.filter { seen.insert($0).inserted }
            let ordered = unique.filter { $0 == me } + unique.filter { $0 != me }
            return ordered.map { user in
                let name = RemoteText.title(names[user] ?? (user == me ? info(key.account)?.name ?? "" : ""))
                return Reactor(
                    id: user, label: user == me ? "You" : (name.isEmpty ? "Unknown" : name), name: name,
                    photoURL: photos[user])
            }
        }
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

    // MARK: Editing and deleting

    /// The composer that edits `message`: a thread reply's thread composer, otherwise the conversation's.
    func composerID(editing message: Message, key: SpaceKey) -> ComposerID {
        ComposerID(key: key, thread: isThreaded(key) && message.isThreadReply ? message.thread : nil)
    }

    func canEdit(_ message: Message, key: SpaceKey) -> Bool {
        !message.isDeleted && message.sender.name == info(key.account)?.me && message.privateViewer == nil
            && canReact(key.account)
    }

    func canDelete(_ message: Message, key: SpaceKey) -> Bool {
        guard !message.isDeleted, canReact(key.account) else { return false }
        return message.sender.name == info(key.account)?.me || openRole == .manager || openRole == .assistantManager
    }

    /// Hands `message` to the composer that edits it, opening its thread first if needed.
    func beginEdit(_ message: Message, key: SpaceKey) {
        guard selection == key, canEdit(message, key: key) else { return }
        let id = composerID(editing: message, key: key)
        if let thread = id.thread, openThread != thread { openThread(thread) }
        editRequests[id] = EditRequest(message: message.name)
    }

    /// The newest message of mine in this composer's part of the conversation, for Up arrow.
    func lastEditable(for id: ComposerID) -> Message? {
        guard selection == id.key else { return nil }
        let rows = id.thread == nil ? openMessages : threadMessages
        return rows.last { composerID(editing: $0, key: id.key) == id && canEdit($0, key: id.key) }
    }

    /// The request the composer should start now; marks it started so a later remount doesn't start it again.
    func takeEditRequest(_ id: ComposerID) -> EditRequest? {
        guard var request = editRequests[id], !request.started else { return nil }
        request.started = true
        editRequests[id] = request
        return request
    }

    /// True while `attempt` is still the composer's current edit.
    func isCurrentEdit(_ attempt: UUID, in id: ComposerID) -> Bool { editRequests[id]?.id == attempt }

    /// Ends the edit if it is still `attempt`, or whatever edit is there when nil.
    func endEdit(_ id: ComposerID, attempt: UUID?) {
        guard let current = editRequests[id], attempt == nil || current.id == attempt else { return }
        editRequests[id] = nil
    }

    func stashDraft(_ draft: StashedDraft, for id: ComposerID) { stashedDrafts[id] = draft }

    func hasStashedDraft(_ id: ComposerID) -> Bool { stashedDrafts[id] != nil }

    /// Lets a rebuilt composer take its edit again.
    func restartEdit(_ id: ComposerID) { editRequests[id]?.started = false }

    /// Edits in composers that are going away end; their drafts were saved when the edits began.
    private func endEdits(where leaving: (ComposerID) -> Bool) {
        for id in editRequests.keys where leaving(id) {
            editRequests[id] = nil
            stashedDrafts[id] = nil
        }
    }

    /// A one-line problem above the conversation's composer.
    func showComposerNotice(_ text: String) { sendError = text }

    func takeStashedDraft(_ id: ComposerID) -> StashedDraft? { stashedDrafts.removeValue(forKey: id) }

    func editableCopy(of name: MessageName, key: SpaceKey) async -> Result<EditableCopy, EditFailure> {
        guard let session = sessions[key.account] else { return .failure(.message("This account is gone.")) }
        do {
            return .success(try await session.editableCopy(of: name))
        } catch {
            return .failure(.message(Self.describe(edit: error)))
        }
    }

    func saveEdit(
        _ name: MessageName, text: String, basedOn: Timestamp, key: SpaceKey
    ) async -> Result<Message, EditFailure> {
        guard let session = sessions[key.account] else { return .failure(.message("This account is gone.")) }
        do {
            let updated = try await session.editMessage(name, text: text, basedOn: basedOn)
            replaceLoaded(updated)
            if selection == key { requestReload() }
            return .success(updated)
        } catch .changedElsewhere(let latest) {
            replaceLoaded(latest)
            return .failure(.changed(latest))
        } catch {
            return .failure(.message(Self.describe(edit: error)))
        }
    }

    func requestDelete(_ message: Message, key: SpaceKey, replies: Int) {
        guard canDelete(message, key: key) else { return }
        let threadStarter = !message.isThreadReply && replies > 0
        pendingDelete = DeleteRequest(key: key, message: message, force: threadStarter)
    }

    func performDelete(_ request: DeleteRequest) async {
        pendingDelete = nil
        guard let session = sessions[request.key.account] else { return }
        do {
            try await session.deleteMessage(request.message.name, force: request.force)
        } catch .hasReplies {
            pendingDelete = DeleteRequest(key: request.key, message: request.message, force: true)
            return
        } catch {
            sendError = Self.describe(edit: error, deleting: true)
            return
        }
        locallyDeleted.insert(request.message.name)
        if request.force, let thread = request.message.thread {
            deletedThreads.insert(thread)
            if openThread == thread { closeThread() }
        }
        for (id, edit) in editRequests where edit.message == request.message.name { editRequests[id] = nil }
        openMessages = withLocalDeletes(openMessages)
        threadMessages = withLocalDeletes(threadMessages)
        if selection == request.key { requestReload() }
    }

    private func replaceLoaded(_ message: Message) {
        func replace(_ list: [Message]) -> [Message] {
            list.contains { $0.name == message.name } ? Self.merged(list, [message]) : list
        }
        history = replace(history)
        openMessages = replace(openMessages)
        threadMessages = replace(threadMessages)
    }

    private func withLocalDeletes(_ messages: [Message]) -> [Message] {
        guard !locallyDeleted.isEmpty || !deletedThreads.isEmpty else { return messages }
        return messages.map { message in
            let inDeletedThread = message.isThreadReply && message.thread.map(deletedThreads.contains) == true
            guard !message.isDeleted, locallyDeleted.contains(message.name) || inDeletedThread else { return message }
            var tombstone = Message(
                name: message.name, sender: message.sender, createTime: message.createTime,
                deleteTime: message.version, thread: message.thread, isThreadReply: message.isThreadReply)
            tombstone.lastUpdateTime = message.lastUpdateTime
            return tombstone
        }
    }

    static func describe(edit error: MessageEditError, deleting: Bool = false) -> String {
        switch error {
        case .notAdmitted: "This account is offline or paused. Try again when it's connected."
        case .changedElsewhere: "This message changed somewhere else. Save again to replace that version."
        case .hasReplies: "This message has replies."
        case .denied: deleting ? "Google didn't allow deleting this message." : "Google didn't allow this edit."
        case .gone: "This message no longer exists."
        case .failed: deleting ? "Could not delete the message." : "Could not save the edit."
        }
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
