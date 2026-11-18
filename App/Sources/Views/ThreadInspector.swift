import ChatModel
import SwiftUI

struct ThreadInspector: View {
    let model: AppModel
    let key: SpaceKey
    let thread: ThreadName

    var body: some View {
        let rows = MessageRowModel.build(model.threadMessages, threaded: false, showsReplies: false)
        let context = model.messageContext(for: key)
        let outbox = model.openOutbox.filter { $0.payload.thread == thread }
        VStack(spacing: 0) {
            HStack {
                Text("Thread").font(.title3.weight(.semibold))
                Spacer()
                Button {
                    model.closeThread()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close thread")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        MessageRow(row: row, context: context, onOpenThread: nil)
                            .id(row.id)
                    }
                    ForEach(outbox) { item in
                        OutboxRow(
                            item: item, context: context,
                            onRepost: { Task { await model.repostAsNewMessage(item, key: key) } },
                            onDiscard: { Task { await model.discard(item, key: key) } }
                        )
                    }
                }
                .scrollTargetLayout()
                .padding(10)
            }
            .onScrollTargetVisibilityChange(idType: MessageName.self, threshold: 0.1) { visible in
                let names = Set(visible)
                let newest = rows.lazy.map(\.message).filter { names.contains($0.name) && !$0.isDeleted }
                    .map(\.createTime).max()
                model.threadViewportChanged(key, thread: thread, newest: newest)
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            ComposerView(model: model, key: key, thread: thread)
                .id(thread)
        }
    }
}
