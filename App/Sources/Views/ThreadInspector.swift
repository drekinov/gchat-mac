import ChatModel
import SwiftUI

/// An open thread, shown in place under its first message: the replies, any replies still sending, and a reply
/// field.
struct InlineThread: View {
    let model: AppModel
    let key: SpaceKey
    let thread: ThreadName
    let context: MessageContext
    @State private var visible = false
    @State private var dropTargeted = false

    var body: some View {
        let replies = model.threadMessages.filter(\.isThreadReply)
        let rows = MessageRowModel.build(replies, threaded: false, showsReplies: false).map { row in
            var row = row
            row.timeHeader = nil
            return row
        }
        let outbox = model.openOutbox.filter { $0.payload.thread == thread }
        VStack(alignment: .leading, spacing: 6) {
            // Drops on the replies go to this thread's reply field. The field sits outside this destination, so
            // text dragged onto it still reaches its text view.
            VStack(alignment: .leading, spacing: 2) {
                if rows.isEmpty && outbox.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
                ForEach(rows) { row in
                    MessageRow(row: row, context: context, compact: true)
                }
                ForEach(outbox) { item in
                    OutboxRow(
                        item: item, context: context,
                        onRepost: { Task { await model.repostAsNewMessage(item, key: key) } },
                        onDiscard: { Task { await model.discard(item, key: key) } }
                    )
                }
            }
            .dropDestination(for: DroppedFile.self) { drops, _ in
                model.addDroppedFiles(drops, to: ComposerID(key: key, thread: thread))
            } isTargeted: {
                dropTargeted = $0
            }
            ComposerView(model: model, key: key, thread: thread, conversationDropTargeted: dropTargeted)
                .id(ComposerID(key: key, thread: thread))
        }
        .padding(.vertical, 8)
        .padding(.leading, 6)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.25)).frame(width: 2)
        }
        .padding(.leading, context.showsAvatars ? 36 : 4)
        .padding(.trailing, 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thread replies")
        .onAppear {
            visible = true
            reportRead(replies)
        }
        .onDisappear { visible = false }
        .onChange(of: model.threadMessages.last?.id) { reportRead(model.threadMessages.filter(\.isThreadReply)) }
    }

    /// The replies are on screen while the open thread is, so its read position follows the newest one.
    private func reportRead(_ replies: [Message]) {
        guard visible else { return }
        let newest = replies.lazy.filter { !$0.isDeleted }.map(\.createTime).max()
        model.threadViewportChanged(key, thread: thread, newest: newest)
    }
}
