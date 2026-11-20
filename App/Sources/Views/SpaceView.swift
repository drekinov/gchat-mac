import ChatModel
import ChatSync
import SwiftUI

struct SpaceView: View {
    let model: AppModel
    let key: SpaceKey
    @Environment(\.isSnapshotMode) private var snapshotMode
    @State private var dropTargeted = false
    @State private var members: [Membership] = []

    var body: some View {
        VStack(spacing: 0) {
            // Offscreen snapshots have no window toolbar, so they show the title and buttons above the messages.
            if snapshotMode {
                SpaceTitle(model: model, key: key, members: members)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .overlay(alignment: .trailing) {
                        HStack(spacing: 2) { SpaceActions(model: model, key: key, members: members) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .padding(.horizontal, 4)
                            .modifier(GlassCapsule(flat: true))
                            .padding(.trailing, 14)
                    }
            }
            MessageList(model: model, key: key, dropTargeted: $dropTargeted)
            ComposerView(model: model, key: key, thread: nil, conversationDropTargeted: dropTargeted)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            if !snapshotMode {
                ToolbarItem(placement: .principal) {
                    SpaceTitle(model: model, key: key, members: members)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItemGroup(placement: .primaryAction) {
                    SpaceActions(model: model, key: key, members: members).labelStyle(.iconOnly)
                }
            }
        }
        .task(id: key) {
            model.prepareMentions(for: key)
            members = await model.memberships(for: key)
        }
        .onChange(of: model.snapshots[key.account]?.revision) {
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
                        Image(systemName: showsMembers ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
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
            let context = model.messageContext(for: key)
            HStack(spacing: -8) {
                ForEach(others.prefix(3), id: \.name) { membership in
                    PhotoAvatar(
                        name: RemoteText.title(membership.member.displayName ?? ""),
                        url: context.photoURL(membership.member.name), media: context.media, size: 24
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

/// The conversation's toolbar buttons: its history setting, message search and the members.
struct SpaceActions: View {
    let model: AppModel
    let key: SpaceKey
    let members: [Membership]
    @State private var showsDetails = false

    var body: some View {
        if let historyOn = model.summary(for: key)?.historyOn, !historyOn {
            HistoryBadge(historyOn: historyOn)
        }
        Button {
            model.showsMessageSearch = true
        } label: {
            Label("Search messages", systemImage: "magnifyingglass")
        }
        .help("Search messages (Cmd-F)")
        Button {
            showsDetails.toggle()
        } label: {
            Label("Members and details", systemImage: "info.circle")
        }
        .help("Members and details")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            MembersPopover(model: model, key: key, members: members) { showsDetails = false }
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

/// Google Chat's per-conversation history setting; the org's retention rules apply only while it's on.
struct HistoryBadge: View {
    let historyOn: Bool

    var body: some View {
        Label(historyOn ? "History on" : "History off", systemImage: historyOn ? "clock.arrow.circlepath" : "timer")
            .labelStyle(.iconOnly)
            .font(.callout)
            .foregroundStyle(historyOn ? Color.secondary : Theme.warning)
            .help(
                historyOn
                    ? "History is on: messages are kept according to your organization's retention policy."
                    : "History is off: messages are deleted after about 24 hours.")
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
        let openThread = model.openThread
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
                            model: model, key: key, thread: openThread, context: context, expectedReplies: row.replies
                        )
                        .listRowSeparator(.hidden)
                        .id(Self.openThread)
                    }
                }
                // A thread whose first message isn't loaded (older than the loaded history) opens at the end.
                if let openThread, !rows.contains(where: { $0.message.thread == openThread }) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Thread").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Close") { model.closeThread() }.buttonStyle(.link).font(.caption)
                        }
                        .padding(.leading, context.showsAvatars ? 42 : 10)
                        .padding(.trailing, 24)
                        InlineThread(model: model, key: key, thread: openThread, context: context)
                    }
                    .listRowSeparator(.hidden)
                    .id(Self.openThread)
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
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            // The stronger edge effect hides messages that scroll under the toolbar, so its title stays readable.
            .scrollEdgeEffectStyle(.hard, for: .top)
            .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
                let atBottom = new.contentOffset.y + new.containerSize.height >= new.contentSize.height - 24
                if new.contentSize.height == old.contentSize.height {
                    if abs(new.contentOffset.y - old.contentOffset.y) > 0.5 { pinned = atBottom }
                } else if pinned && !atBottom {
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
                if let previous, !pinned, !model.history.isEmpty { proxy.scrollTo(previous, anchor: .top) }
            }
            .onChange(of: model.openMessages.last?.id) { scroll(proxy, animated: true) }
            .onChange(of: model.openOutbox.count) { scroll(proxy, animated: true) }
            .onChange(of: model.openThread) { _, thread in
                guard let thread else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation { reveal(thread, proxy) }
                }
            }
            .onChange(of: model.revealSequence) {
                guard let name = model.revealedMessage else { return }
                let reply = model.openMessages.first { $0.name == name }.map(\.isThreadReply) ?? true
                pinned = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    // A reply lives inside its open thread, which is reached through the thread's first message.
                    if reply, let thread = model.openThread {
                        reveal(thread, proxy)
                    } else {
                        withAnimation { proxy.scrollTo(name, anchor: .center) }
                    }
                }
            }
            .onChange(of: model.scrollCommand) {
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
                try? await Task.sleep(for: .milliseconds(250))
                reveal(thread, proxy)
                // Rows above settle their heights once on screen, which moves the target; land on it again.
                try? await Task.sleep(for: .milliseconds(300))
                reveal(thread, proxy)
            }
        }
    }

    /// Drops on the conversation's rows attach to its composer. Each row takes them itself: the list routes drops
    /// to its rows, and an open thread's rows and reply field send theirs to the thread instead.
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
    /// thread's own row only exists once it's on screen. A thread opened at the end is reached from the bottom.
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
                    SettingsLink { Text("Settings").font(.caption) }.buttonStyle(.link)
                }
            case .failed:
                Button("Couldn't load earlier messages. Retry") { model.retryHistory() }.buttonStyle(.link)
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool, force: Bool = false) {
        if force { pinned = true }
        guard pinned else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(force ? 120 : 30))
            if animated {
                withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            } else {
                proxy.scrollTo(Self.bottom, anchor: .bottom)
            }
        }
    }
}
