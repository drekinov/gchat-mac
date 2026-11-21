import ChatModel
import ChatSync
import SwiftUI

struct SpaceView: View {
    let model: AppModel
    let key: SpaceKey
    @Environment(\.isSnapshotMode) private var snapshotMode
    @Environment(\.titlebarHeight) private var titlebarHeight
    @State private var dropTargeted = false
    @State private var members: [Membership] = []

    var body: some View {
        VStack(spacing: 0) {
            MessageList(model: model, key: key, dropTargeted: $dropTargeted)
                // The title is centred over the conversation, not the window. Offscreen snapshots have no toolbar,
                // so they also show the buttons here.
                .safeAreaBar(edge: .top, spacing: 0) {
                    SpaceTitle(model: model, key: key, members: members)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 120)
                        .background { WindowDragArea() }
                        .overlay(alignment: .trailing) {
                            if snapshotMode {
                                HStack(spacing: 2) { SpaceActions(model: model, key: key, members: members) }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                    .padding(.horizontal, 4)
                                    .modifier(GlassCapsule(flat: true))
                                    .padding(.trailing, 14)
                            }
                        }
                        .frame(height: titlebarHeight)
                        // Solid, like the window, so messages scrolling under it never show through the title.
                        .background(Color(nsColor: .textBackgroundColor))
                }
            ComposerView(model: model, key: key, thread: nil, conversationDropTargeted: dropTargeted)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            if !snapshotMode {
                ToolbarItemGroup {
                    SpaceActions(model: model, key: key, members: members).labelStyle(.iconOnly)
                }
            }
        }
        .task(id: key) {
            model.prepareMentions(for: key)
            members = await model.memberships(for: key)
        }
        .onChange(of: model.summary(for: key)?.membersFetched) {
            Task { members = await model.memberships(for: key) }
        }
    }
}

/// The conversation's name in the middle of the toolbar, with a few members' faces and the account it belongs to.
/// Clicking it shows the members.
struct SpaceTitle: View {
    let model: AppModel
    let key: SpaceKey
    let members: [Membership]
    @State private var showsMembers = false

    var body: some View {
        let summary = model.summary(for: key)
        let title = RemoteText.title(summary?.title ?? "")
        let account = model.info(key.account)
        Button {
            showsMembers.toggle()
        } label: {
            HStack(spacing: 8) {
                faces(title: title, summary: summary)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 3) {
                        Text(title).font(.headline).lineLimit(1)
                        if summary?.isMuted == true {
                            Image(systemName: "bell.slash.fill").font(.caption).foregroundStyle(.secondary)
                                .accessibilityLabel("Muted")
                        }
                        // One chevron that turns, in a slot as wide as it is when pointing down, so the centred
                        // title doesn't shift when the members open.
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showsMembers ? 90 : 0))
                            .frame(width: 11)
                            .animation(.smooth(duration: 0.2), value: showsMembers)
                            .accessibilityHidden(true)
                    }
                    HStack(spacing: 4) {
                        AccountBadge(info: account, size: 11)
                        Text(RemoteText.title(account?.name ?? "")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show members")
        .accessibilityLabel("\(title) in \(RemoteText.title(account?.name ?? "")), show members")
        .popover(isPresented: $showsMembers, arrowEdge: .bottom) {
            MembersPopover(model: model, key: key, members: members) { showsMembers = false }
        }
    }

    /// Up to three other members' photos; the conversation's own picture until members are known.
    @ViewBuilder
    private func faces(title: String, summary: SpaceSummary?) -> some View {
        let me = model.info(key.account)?.me
        let others = members.filter {
            $0.state == .joined && $0.member.type == .human && !$0.member.isAnonymous && $0.member.name != me
        }
        if others.isEmpty {
            SpaceAvatar(title: title, kind: kind(summary), size: 26)
        } else {
            let media = model.mediaLoader(for: key.account)
            HStack(spacing: -8) {
                ForEach(others.prefix(3), id: \.name) { membership in
                    PhotoAvatar(
                        name: RemoteText.title(membership.member.displayName ?? ""),
                        url: model.photoURL(membership.member.name, account: key.account), media: media, size: 24
                    )
                    .padding(1.5)
                    .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                }
            }
        }
    }

    private func kind(_ summary: SpaceSummary?) -> SpaceKind {
        switch summary?.type {
        case .groupChat: .group
        case .directMessage: summary?.isBotDM == true ? .bot : .directMessage
        default: .space
        }
    }
}

/// The conversation's toolbar buttons: message search and its details.
struct SpaceActions: View {
    let model: AppModel
    let key: SpaceKey
    let members: [Membership]
    @State private var showsDetails = false

    var body: some View {
        Button {
            model.showsMessageSearch = true
        } label: {
            Label("Search messages", systemImage: "magnifyingglass")
        }
        .help("Search messages (Cmd-F)")
        Button {
            showsDetails.toggle()
        } label: {
            Label("Conversation details", systemImage: "info.circle")
        }
        .help("Conversation details")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            ConversationDetailsPopover(model: model, key: key, members: members)
        }
    }
}

/// Liquid Glass behind a group of toolbar-like buttons. Offscreen snapshots can't draw glass, and it hides what's
/// on it there, so they get a flat capsule instead.
struct GlassCapsule: ViewModifier {
    let flat: Bool

    func body(content: Content) -> some View {
        if flat {
            content.background(Color.primary.opacity(0.06), in: Capsule())
        } else {
            content.glassEffect(.regular, in: .capsule)
        }
    }
}

struct MessageList: View {
    let model: AppModel
    let key: SpaceKey
    @Binding var dropTargeted: Bool
    /// Follows the newest message until the user scrolls away; content growing (cards, late layout) keeps it.
    @State private var pinned = true
    /// Rows a drag is over; the composer shows its drop outline while there's at least one.
    @State private var dropRows = 0
    /// The same for the open thread's rows and its reply field.
    @State private var threadDropRows = 0
    @State private var threadViewport = ThreadViewport()
    @State private var listFrame = CGRect.zero
    @State private var pendingScroll: ScrollRequest?
    @State private var scrollSequence = 0

    private static let bottom = "bottom"
    private static let openThread = "open-thread"

    var body: some View {
        if model.loadedKey == key {
            list
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var list: some View {
        let threaded = model.isThreaded(key)
        let rows = MessageRowModel.build(model.openMessages, threaded: threaded, showsReplies: threaded)
        var context = model.messageContext(for: key)
        let isDirectMessage = model.summary(for: key)?.type == .directMessage
        context.showsSenderNames = !isDirectMessage
        context.showsAvatars = !isDirectMessage
        let outbox = model.openOutbox.filter { $0.payload.thread == nil || !threaded }
        let openThread = threaded ? model.openThread : nil
        return ScrollViewReader { proxy in
            List {
                if !rows.isEmpty {
                    takesDrops(historyHeader.frame(maxWidth: .infinity))
                        .listRowSeparator(.hidden)
                }
                ForEach(rows) { row in
                    let isOpen = openThread != nil && row.message.thread == openThread
                    takesDrops(
                        MessageRow(
                            row: row, context: context, onOpenThread: threaded ? { toggle($0) } : nil,
                            threadOpen: isOpen)
                    )
                    .listRowSeparator(.hidden)
                    .id(row.id)
                    if isOpen, let openThread {
                        InlineThread(
                            model: model, key: key, thread: openThread, context: context, expectedReplies: row.replies,
                            viewport: threadViewport, listFrame: listFrame, dropRows: $threadDropRows)
                    }
                }
                // A thread whose first message isn't loaded (older than the loaded history) opens at the end.
                if let openThread, !rows.contains(where: { $0.message.thread == openThread }) {
                    HStack {
                        Text("Thread").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Close") { model.closeThread() }.buttonStyle(.link).font(.caption)
                    }
                    .padding(.leading, context.showsAvatars ? 42 : 10)
                    .padding(.trailing, 24)
                    .listRowSeparator(.hidden)
                    .id(Self.openThread)
                    InlineThread(
                        model: model, key: key, thread: openThread, context: context, viewport: threadViewport,
                        listFrame: listFrame, dropRows: $threadDropRows)
                }
                ForEach(outbox) { item in
                    takesDrops(
                        OutboxRow(
                            item: item, context: context,
                            onRepost: { Task { await model.repostAsNewMessage(item, key: key) } },
                            onDiscard: { Task { await model.discard(item, key: key) } }
                        )
                    )
                    .listRowSeparator(.hidden)
                }
                takesDrops(Color.clear.frame(height: 1))
                    .listRowSeparator(.hidden)
                    .id(Self.bottom)
            }
            .listStyle(.plain)
            .defaultScrollAnchor(.bottom)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            // The stronger edge effect hides messages that scroll under the toolbar, so its title stays readable.
            .scrollEdgeEffectStyle(.hard, for: .top)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { listFrame = $0 }
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
                let atBottom = new.contentOffset.y + new.containerSize.height >= new.contentSize.height - 24
                if new.contentSize.height == old.contentSize.height {
                    if abs(new.contentOffset.y - old.contentOffset.y) > 0.5 { pinned = atBottom }
                } else if pinned && !atBottom && !revealing {
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
            .overlay {
                if rows.isEmpty && outbox.isEmpty { Text("No messages yet").foregroundStyle(.secondary) }
            }
            .overlay(alignment: .bottom) {
                if !pinned {
                    Button {
                        pinned = true
                        withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                        // A long jump lands short while rows on the way settle their heights; land on it again.
                        scrollLater(.message, after: .milliseconds(400)) {
                            pinned = true
                            proxy.scrollTo(Self.bottom, anchor: .bottom)
                        }
                    } label: {
                        Label("Newest", systemImage: "arrow.down")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .help("Jump to the newest message")
                    .padding(12)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: pinned)
            .onChange(of: rows.first?.id) { previous, _ in
                if let previous, !pinned, !revealing, !model.history.isEmpty {
                    proxy.scrollTo(previous, anchor: .top)
                }
            }
            .onChange(of: model.openMessages.last?.id) { scroll(proxy, animated: true) }
            .onChange(of: model.openOutbox.count) { scroll(proxy, animated: true) }
            .onChange(of: model.openThread) { _, thread in
                threadDropRows = 0
                guard let thread else { return cancelScroll() }
                scrollLater(.thread, after: .milliseconds(80)) { withAnimation { reveal(thread, proxy) } }
            }
            .onChange(of: model.revealSequence) {
                guard let name = model.revealedMessage else { return }
                let reply = threaded && (model.openMessages.first { $0.name == name }.map(\.isThreadReply) ?? true)
                pinned = false
                scrollLater(.message, after: .milliseconds(150)) {
                    guard reply, let thread = model.openThread else {
                        withAnimation { proxy.scrollTo(name, anchor: .center) }
                        return
                    }
                    // A reply's row exists once the thread has loaded it and the list has laid out its first message.
                    for _ in 0..<20 where !model.threadMessages.contains(where: { $0.name == name }) {
                        try? await Task.sleep(for: .milliseconds(150))
                        if Task.isCancelled { return }
                    }
                    reveal(thread, proxy)
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled, model.threadMessages.contains(where: { $0.name == name }) else { return }
                    withAnimation { proxy.scrollTo(name, anchor: .center) }
                }
            }
            .onChange(of: model.scrollCommand) {
                cancelScroll()
                if model.scrollCommand.toTop, let first = rows.first {
                    proxy.scrollTo(first.id, anchor: .top)
                } else {
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
            .task {
                scroll(proxy, animated: false, force: true)
                // A thread that is already open when the conversation appears gets scrolled into view, like one
                // opened from its replies button.
                guard let thread = model.openThread else { return }
                scrollLater(.thread, after: .milliseconds(250)) {
                    reveal(thread, proxy)
                    // Rows above settle their heights once on screen, which moves the target; land on it again.
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled else { return }
                    reveal(thread, proxy)
                }
            }
            .onDisappear { cancelScroll() }
        }
    }

    /// Drops on the conversation's rows attach to its composer. Each row takes them itself: the list routes drops
    /// to its rows, and an open thread's rows send theirs to the thread instead.
    private func takesDrops<V: View>(_ row: V) -> some View {
        row.dropDestination(for: DroppedFile.self) { drops, _ in
            dropRows = 0
            dropTargeted = false
            return model.addDroppedFiles(drops, to: ComposerID(key: key, thread: nil))
        } isTargeted: { over in
            dropRows = max(0, dropRows + (over ? 1 : -1))
            dropTargeted = dropRows > 0
        }
    }

    /// Scrolls an open thread into view by its first message, which the list knows by id even off screen; the
    /// thread's own rows only exist once they're near the screen. A thread opened at the end is reached from the bottom.
    private func reveal(_ thread: ThreadName, _ proxy: ScrollViewProxy) {
        if let root = model.openMessages.first(where: { $0.thread == thread && !$0.isThreadReply }) {
            // Unpin first: the thread growing as it lays out would otherwise scroll back to the newest message.
            pinned = false
            proxy.scrollTo(root.id, anchor: .top)
        } else {
            proxy.scrollTo(Self.bottom, anchor: .bottom)
        }
    }

    private func toggle(_ thread: ThreadName) {
        if model.openThread == thread {
            model.closeThread()
        } else {
            model.openThread(thread)
        }
    }

    @ViewBuilder private var historyHeader: some View {
        if model.loadingHistory {
            ProgressView().controlSize(.small)
        } else {
            switch model.historyEnd {
            case .open:
                Button("Load earlier messages") { model.loadOlder() }
                    .buttonStyle(.link)
                    .onAppear { if !pinned { model.loadOlder() } }
            case .beginning:
                Text("Beginning of conversation").font(.caption).foregroundStyle(.secondary)
            case .capped:
                HStack(spacing: 4) {
                    Text("Earlier messages stop here; the limit is in").font(.caption).foregroundStyle(.secondary)
                    SettingsLink { Text("Settings › General").font(.caption) }.buttonStyle(.link)
                }
            case .failed:
                Button("Couldn't load earlier messages. Retry") { model.retryHistory() }.buttonStyle(.link)
            }
        }
    }

    // MARK: Scrolling

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool, force: Bool = false) {
        if force {
            pinned = true
            // Opening lands short while cards and long rows settle their heights, so it lands a few times.
            scrollLater(.thread, after: .zero) {
                for pause in [0, 120, 250, 450] {
                    try? await Task.sleep(for: .milliseconds(pause))
                    guard !Task.isCancelled else { return }
                    pinned = true
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
            return
        }
        guard pinned else { return }
        scrollLater(.follow, after: .milliseconds(30)) {
            if animated {
                withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            } else {
                proxy.scrollTo(Self.bottom, anchor: .bottom)
            }
        }
    }

    /// A thread or message reveal is waiting; following the newest message holds off until it lands.
    private var revealing: Bool { (pendingScroll?.kind ?? .follow) > .follow }

    /// Runs `body` after `delay` as the list's one pending scroll, replacing the previous one unless that ranks
    /// higher and still applies. It does nothing if the conversation or thread changed, or a follow lost its pin.
    private func scrollLater(
        _ kind: ScrollRequest.Kind, after delay: Duration, _ body: @escaping @MainActor () async -> Void
    ) {
        let selection = model.selection
        let thread = model.openThread
        if let pending = pendingScroll, pending.kind > kind, pending.selection == selection, pending.thread == thread {
            return
        }
        pendingScroll?.task.cancel()
        scrollSequence += 1
        let id = scrollSequence
        let task = Task { @MainActor in
            defer { if pendingScroll?.id == id { pendingScroll = nil } }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, model.selection == selection, model.openThread == thread,
                kind != .follow || pinned
            else { return }
            await body()
        }
        pendingScroll = ScrollRequest(id: id, kind: kind, selection: selection, thread: thread, task: task)
    }

    private func cancelScroll() {
        pendingScroll?.task.cancel()
        pendingScroll = nil
    }
}

private struct ScrollRequest {
    /// Following the newest message, revealing an open thread, revealing one message.
    enum Kind: Int, Comparable {
        case follow, thread, message

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    let id: Int
    let kind: Kind
    let selection: SpaceKey?
    let thread: ThreadName?
    let task: Task<Void, Never>
}
