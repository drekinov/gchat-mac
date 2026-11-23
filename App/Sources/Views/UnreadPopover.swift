import ChatModel
import ChatSync
import SwiftUI

/// The conversation's unread messages, oldest first, including replies inside threads. Clicking one scrolls to it,
/// opening its thread when it's a reply. Read from the store each time it opens, so nothing is kept.
struct UnreadPopover: View {
    let model: AppModel
    let key: SpaceKey
    /// The list, read before the popover opens so it opens at its full height. Without it the popover reads it
    /// itself, for previews.
    var preloaded: UnreadMessages?
    var onClose: () -> Void
    @State private var loaded: UnreadMessages?
    @State private var hovered: MessageName?
    /// The rows' own height. A scroll view asks for less than its content, and the list loads after the popover has
    /// sized itself, so the list is given this height, up to `maxListHeight`, and scrolls past that.
    @State private var rowsHeight: CGFloat = 0

    static let maxListHeight: CGFloat = 420

    var body: some View {
        let context = model.messageContext(for: key)
        let unread = loaded ?? preloaded
        VStack(spacing: 0) {
            Text(title(unread)).font(.headline)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .padding(.horizontal, 16)
            if let unread {
                if unread.messages.isEmpty {
                    Text("No unread messages").font(.callout).foregroundStyle(.secondary).padding(20)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(unread.messages, id: \.name) { message in
                                row(message, root: message.thread.flatMap { unread.roots[$0] }, context: context)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 10)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            rowsHeight = $0
                        }
                    }
                    .frame(height: min(rowsHeight, Self.maxListHeight))
                }
            } else {
                ProgressView().controlSize(.small).padding(20)
            }
        }
        .frame(width: 360)
        .task(id: key) {
            if preloaded == nil { loaded = await model.unreadMessages(for: key) ?? UnreadMessages() }
        }
    }

    private func title(_ unread: UnreadMessages?) -> String {
        guard let count = unread?.messages.count, count > 0 else { return "Unread messages" }
        return count == 1 ? "1 unread message" : "\(count) unread messages"
    }

    private func row(_ message: Message, root: Message?, context: MessageContext) -> some View {
        let sender = name(of: message, context)
        return Button {
            model.reveal(message)
            onClose()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                PhotoAvatar(name: sender, url: context.photoURL(message.sender.name), media: context.media, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(sender).fontWeight(.semibold).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(time(message.createTime)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(RemoteText.message(message.contentPreview ?? "")).lineLimit(2)
                        .foregroundStyle(.secondary)
                    if message.isThreadReply {
                        Label(threadLine(root, context), systemImage: "arrowshape.turn.up.left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(8)
            .background(
                hovered == message.name ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = message.name
            } else if hovered == message.name {
                hovered = nil
            }
        }
        .help(message.isThreadReply ? "Open the thread and go to this reply" : "Go to this message")
    }

    private func name(of message: Message, _ context: MessageContext) -> String {
        let name = message.sender.displayName ?? context.names[message.sender.name] ?? ""
        return name.isEmpty ? "Unknown" : RemoteText.title(name)
    }

    /// Which thread a reply is in: its first message when it's loaded.
    private func threadLine(_ root: Message?, _ context: MessageContext) -> String {
        guard let root else { return "Reply in a thread" }
        let text = RemoteText.message(root.contentPreview ?? "").replacingOccurrences(of: "\n", with: " ")
        return "Reply to \(name(of: root, context)): \(text)"
    }

    private func time(_ time: Timestamp) -> String {
        Calendar.current.isDateInToday(time.date)
            ? "Today \(time.date.formatted(.dateTime.hour().minute()))" : TimeFormat.message(time)
    }
}
