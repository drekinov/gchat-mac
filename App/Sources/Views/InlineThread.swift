import ChatModel
import SwiftUI

/// An open thread's rows under its first message: one list row per reply, any replies still sending, then a reply
/// field. Separate rows let the list create only the replies on screen.
struct InlineThread: View {
    let model: AppModel
    let key: SpaceKey
    let thread: ThreadName
    let context: MessageContext
    /// Replies the conversation already knows of. A thread started from Reply has none, so it shows only the field.
    var expectedReplies = 0
    let viewport: ThreadViewport
    /// Rows a drag is over; the thread's reply field shows its drop outline while there's at least one.
    @Binding var dropRows: Int

    var body: some View {
        let rows = MessageRowModel.build(
            model.threadMessages.filter(\.isThreadReply), threaded: false, showsReplies: false
        )
        .map { row in
            var row = row
            row.timeHeader = nil
            return row
        }
        let outbox = model.openOutbox.filter { $0.payload.thread == thread }
        if rows.isEmpty && outbox.isEmpty && expectedReplies > 0 {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                .modifier(ThreadRail(context: context, top: 8))
        }
        ForEach(rows) { row in
            let name = row.message.name
            takesDrops(MessageRow(row: row, context: context, compact: true))
                .onGeometryChange(for: Bool.self, of: Self.isOnScreen) { onScreen in
                    seen(name, onScreen: onScreen)
                }
                .onDisappear { seen(name, onScreen: false) }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Thread reply")
                .modifier(ThreadRail(context: context, top: row.id == rows.first?.id ? 8 : 1))
                .id(row.id)
        }
        ForEach(outbox) { item in
            takesDrops(
                OutboxRow(
                    item: item, context: context,
                    onRepost: { Task { await model.repostAsNewMessage(item, key: key) } },
                    onDiscard: { Task { await model.discard(item, key: key) } }
                )
            )
            .modifier(ThreadRail(context: context, top: 1))
        }
        ComposerView(model: model, key: key, thread: thread, conversationDropTargeted: dropRows > 0)
            .modifier(ThreadRail(context: context, top: 5, bottom: 8))
            .id(ComposerID(key: key, thread: thread))
    }

    /// A row is on screen when a useful part of it is inside the list's visible area.
    nonisolated private static func isOnScreen(_ proxy: GeometryProxy) -> Bool {
        guard let viewport = proxy.bounds(of: .scrollView) else { return true }
        let shown = CGRect(origin: .zero, size: proxy.size).intersection(viewport).height
        return shown >= min(24, proxy.size.height)
    }

    private func seen(_ name: MessageName, onScreen: Bool) {
        guard thread == model.openThread, viewport.update(name, in: thread, onScreen: onScreen) else { return }
        model.threadViewportChanged(key, thread: thread, newest: viewport.newest(in: model.threadMessages))
    }

    /// Drops on the thread's rows attach to its reply field.
    private func takesDrops<V: View>(_ row: V) -> some View {
        row.dropDestination(for: DroppedFile.self) { drops, _ in
            dropRows = 0
            return model.addDroppedFiles(drops, to: ComposerID(key: key, thread: thread))
        } isTargeted: { over in
            dropRows = max(0, dropRows + (over ? 1 : -1))
        }
    }
}

/// The thread's left rail and indent, drawn per row with no gap between rows so it reads as one line.
private struct ThreadRail: ViewModifier {
    let context: MessageContext
    var top: CGFloat = 1
    var bottom: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .padding(.top, top)
            .padding(.bottom, bottom)
            .padding(.leading, 6)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.25)).frame(width: 2)
            }
            .padding(.leading, context.showsAvatars ? 36 : 4)
            .padding(.trailing, 24)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
    }
}

/// The open thread's replies on screen. A plain object, so scrolling doesn't redraw the conversation.
@MainActor
final class ThreadViewport {
    private var thread: ThreadName?
    private var visible: Set<MessageName> = []

    /// Records one row; false when nothing changed.
    func update(_ name: MessageName, in thread: ThreadName, onScreen: Bool) -> Bool {
        if thread != self.thread {
            self.thread = thread
            visible = []
        }
        return onScreen ? visible.insert(name).inserted : visible.remove(name) != nil
    }

    func newest(in replies: [Message]) -> Timestamp? {
        Message.newestVisibleReply(in: replies, visible: visible)
    }
}
