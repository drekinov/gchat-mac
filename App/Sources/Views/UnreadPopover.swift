import ChatModel
import ChatSync
import SwiftUI

/// The conversation's unread messages, oldest first, including replies inside threads. Clicking one scrolls to it,
/// opening its thread when it's a reply. Read when it opens and again whenever the conversation changes meanwhile.
struct UnreadPopover: View {
    let model: AppModel
    let key: SpaceKey
    var members: [Membership] = []

    static let rowHeight: CGFloat = 64
    static let minListHeight: CGFloat = 120
    static let maxListHeight: CGFloat = 420

    /// Fixed while the popover is open, from the count it opened with (nil: full height), so a spinner, an error or a
    /// growing list leaves its size alone; rows scroll past it.
    static func listHeight(for count: Int?) -> CGFloat {
        guard let count else { return maxListHeight }
        return min(max(CGFloat(min(count, 100)) * rowHeight + 10, minListHeight), maxListHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .padding(.horizontal, 16)
            content
                .frame(maxWidth: .infinity)
                .frame(height: Self.listHeight(for: model.unreadSizedFor))
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking threads…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.bottom, 8)
            .opacity(model.unreadIsUpdating ? 1 : 0)
            .accessibilityHidden(!model.unreadIsUpdating)
        }
        .frame(width: 360)
    }

    @ViewBuilder private var content: some View {
        switch model.unreadState {
        case .loading:
            ProgressView().controlSize(.small)
        case .failed:
            VStack(spacing: 10) {
                Text("Couldn't load the unread messages.").font(.callout).foregroundStyle(.secondary)
                Button("Try Again") { model.retryUnread() }
            }
            .padding(.horizontal, 20)
        case .loaded(let unread):
            if unread.messages.isEmpty {
                Text("No unread messages").font(.callout).foregroundStyle(.secondary)
            } else {
                list(unread)
            }
        }
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
                        model.closeUnread()
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
    }

    private var title: String {
        guard case .loaded(let unread) = model.unreadState, unread.messages.count > 0 else { return "Unread messages" }
        let count = unread.messages.count
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
