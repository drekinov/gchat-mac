import ChatModel
import ChatSync
import SwiftUI

/// The conversation's unread messages, oldest first, including replies inside threads. Clicking one scrolls to it,
/// opening its thread when it's a reply. Read from the store each time it opens, so nothing is kept.
struct UnreadPopover: View {
    let model: AppModel
    let key: SpaceKey
    /// The list, read before the popover opens so it opens at its full height; nil when the store couldn't be read.
    let unread: UnreadMessages?
    var members: [Membership] = []
    var onRetry: () -> Void = {}
    var onClose: () -> Void

    /// A scroll view's natural height is its rows' height, so with the list already read the popover opens that tall,
    /// up to this, and scrolls past it.
    static let maxListHeight: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .padding(.horizontal, 16)
            if let unread {
                if unread.messages.isEmpty {
                    Text("No unread messages").font(.callout).foregroundStyle(.secondary).padding(20)
                } else {
                    list(unread)
                }
            } else {
                VStack(spacing: 10) {
                    Text("Couldn't load the unread messages.").font(.callout).foregroundStyle(.secondary)
                    Button("Try Again", action: onRetry)
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 18)
            }
        }
        .frame(width: 360)
    }

    private func list(_ unread: UnreadMessages) -> some View {
        let names = senderNames(unread)
        let media = model.mediaLoader(for: key.account)
        return ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(unread.messages, id: \.name) { message in
                    UnreadRow(
                        message: message, root: message.thread.flatMap { unread.roots[$0] }, names: names,
                        photoURL: model.photoURL(message.sender.name, account: key.account), media: media
                    ) {
                        model.reveal(message)
                        onClose()
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .frame(maxHeight: Self.maxListHeight)
    }

    private var title: String {
        guard let count = unread?.messages.count, count > 0 else { return "Unread messages" }
        return count == 1 ? "1 unread message" : "\(count) unread messages"
    }

    /// Names for this list only: the members, then the senders it holds. It never walks the conversation's history.
    private func senderNames(_ unread: UnreadMessages) -> [UserName: String] {
        var names: [UserName: String] = [:]
        for membership in members {
            if let name = membership.member.displayName, !name.isEmpty { names[membership.member.name] = name }
        }
        for message in unread.messages + unread.roots.values where names[message.sender.name] == nil {
            if let name = message.sender.displayName, !name.isEmpty { names[message.sender.name] = name }
        }
        return names
    }
}

/// One unread message. It keeps its own hover state, so moving the pointer redraws only the rows it crosses.
private struct UnreadRow: View {
    let message: Message
    let root: Message?
    let names: [UserName: String]
    let photoURL: URL?
    let media: MediaLoader?
    let onSelect: () -> Void
    @State private var hovered = false

    var body: some View {
        let sender = name(of: message)
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 10) {
                PhotoAvatar(name: sender, url: photoURL, media: media, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(sender).fontWeight(.semibold).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(time).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(RemoteText.message(message.contentPreview ?? "")).lineLimit(2)
                        .foregroundStyle(.secondary)
                    if message.isThreadReply {
                        Label(threadLine, systemImage: "arrowshape.turn.up.left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(8)
            .background(hovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(message.isThreadReply ? "Open the thread and go to this reply" : "Go to this message")
    }

    private func name(of message: Message) -> String {
        let name = names[message.sender.name] ?? message.sender.displayName ?? ""
        return name.isEmpty ? "Unknown" : RemoteText.title(name)
    }

    /// Which thread a reply is in: its first message when it's loaded.
    private var threadLine: String {
        guard let root else { return "Reply in a thread" }
        let text = RemoteText.message(root.contentPreview ?? "").replacingOccurrences(of: "\n", with: " ")
        return "Reply to \(name(of: root)): \(text)"
    }

    private var time: String {
        let time = message.createTime
        return Calendar.current.isDateInToday(time.date)
            ? "Today \(time.date.formatted(.dateTime.hour().minute()))" : TimeFormat.message(time)
    }
}
