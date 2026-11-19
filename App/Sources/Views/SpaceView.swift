import ChatModel
import ChatSync
import SwiftUI

struct SpaceView: View {
    let model: AppModel
    let key: SpaceKey
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            SpaceHeader(model: model, key: key)
            Divider()
            // Drops on the messages attach to the composer. This destination must not cover the composer: there it
            // would sit above the text view, which then never gets dragged text, and the composer's own
            // destination never gets files.
            MessageList(model: model, key: key)
                .dropDestination(for: DroppedFile.self) { drops, _ in
                    model.addDroppedFiles(drops, to: ComposerID(key: key, thread: nil))
                } isTargeted: {
                    dropTargeted = $0
                }
            Divider()
            ComposerView(model: model, key: key, thread: nil, conversationDropTargeted: dropTargeted)
        }
    }
}

struct SpaceHeader: View {
    let model: AppModel
    let key: SpaceKey

    var body: some View {
        let summary = model.summary(for: key)
        HStack(spacing: 10) {
            Text(RemoteText.title(summary?.title ?? ""))
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            if summary?.isMuted == true {
                Image(systemName: "bell.slash.fill").foregroundStyle(.secondary).accessibilityLabel("Muted")
            }
            Spacer()
            if let historyOn = summary?.historyOn {
                HistoryBadge(historyOn: historyOn)
            }
            AccountChip(info: model.info(key.account))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Google Chat's per-conversation history setting; the org's retention rules apply only while it's on.
struct HistoryBadge: View {
    let historyOn: Bool

    var body: some View {
        Label(historyOn ? "History on" : "History off", systemImage: historyOn ? "clock.arrow.circlepath" : "timer")
            .font(.caption)
            .foregroundStyle(historyOn ? Color.secondary : Color.orange)
            .help(
                historyOn
                    ? "Messages are kept according to your organization's retention policy."
                    : "History is off: messages are deleted after about 24 hours.")
    }
}

struct MessageList: View {
    let model: AppModel
    let key: SpaceKey
    /// Follows the newest message until the user scrolls away; content growing (cards, late layout) keeps it.
    @State private var pinned = true

    private static let bottom = "bottom"

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
        let context = model.messageContext(for: key)
        let outbox = model.openOutbox.filter { $0.payload.thread == nil || !threaded }
        return ScrollViewReader { proxy in
            List {
                ForEach(rows) { row in
                    MessageRow(row: row, context: context, onOpenThread: threaded ? { model.openThread($0) } : nil)
                        .listRowSeparator(.hidden)
                        .id(row.id)
                }
                ForEach(outbox) { item in
                    OutboxRow(
                        item: item, context: context,
                        onRepost: { Task { await model.repostAsNewMessage(item, key: key) } },
                        onDiscard: { Task { await model.discard(item, key: key) } }
                    )
                    .listRowSeparator(.hidden)
                }
                Color.clear
                    .frame(height: 1)
                    .listRowSeparator(.hidden)
                    .id(Self.bottom)
            }
            .listStyle(.plain)
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
            .overlay(alignment: .bottomTrailing) {
                if !pinned {
                    Button {
                        pinned = true
                        withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down").font(.body.weight(.semibold)).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Jump to the newest message")
                    .padding(14)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: pinned)
            .onChange(of: model.openMessages.last?.id) { scroll(proxy, animated: true) }
            .onChange(of: model.openOutbox.count) { scroll(proxy, animated: true) }
            .onChange(of: model.scrollCommand) {
                if model.scrollCommand.toTop, let first = rows.first {
                    proxy.scrollTo(first.id, anchor: .top)
                } else {
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
            .task { scroll(proxy, animated: false, force: true) }
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
