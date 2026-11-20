import AppKit
import SwiftUI

struct QuickSwitcher: View {
    let model: AppModel
    var onClose: () -> Void = {}
    @State private var query = ""
    @State private var highlight = 0
    @FocusState private var focused: Bool

    private var results: [InboxEntry] {
        let all = model.entries(for: nil)
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return Array(all.prefix(12)) }
        return all.filter { entry in
            RemoteText.title(entry.summary.title).lowercased().contains(needle)
                || (model.info(entry.account)?.name.lowercased().contains(needle) ?? false)
        }.prefix(12).map { $0 }
    }

    var body: some View {
        let entries = results
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Jump to a conversation", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit { open(entries, highlight) }
                    .onKeyPress(.downArrow) {
                        highlight = min(highlight + 1, max(entries.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlight = max(highlight - 1, 0)
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
            Divider()
            if entries.isEmpty {
                Text("No matching conversations")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        row(entry, selected: index == highlight)
                            .contentShape(Rectangle())
                            .onTapGesture { open(entries, index) }
                    }
                }
                .padding(6)
            }
            Divider()
            HStack(spacing: 14) {
                Text("↑↓ to move")
                Text("Return to open")
                Text("Esc to close")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityHidden(true)
        }
        .frame(width: 500)
        .onChange(of: query) { highlight = 0 }
        .onExitCommand(perform: onClose)
        .task { focused = true }
    }

    private func row(_ entry: InboxEntry, selected: Bool) -> some View {
        let account = model.info(entry.account)
        let title = RemoteText.title(entry.summary.title)
        return HStack(spacing: 10) {
            ConversationIcon(kind: model.kind(of: entry), title: title, account: account)
            Text(title)
                .fontWeight(entry.hasUnread ? .semibold : .regular)
                .lineLimit(1)
            Spacer(minLength: 8)
            if entry.hasUnread { UnreadPill(count: entry.unread) }
            Text(RemoteText.title(account?.name ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(selected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func open(_ entries: [InboxEntry], _ index: Int) {
        guard entries.indices.contains(index) else { return }
        model.select(entries[index].id)
        onClose()
    }
}

/// Initials in a circle for a person, a symbol on a rounded square for a space, with the account's badge on the
/// corner so two accounts' chats with the same name stay apart.
private struct ConversationIcon: View {
    let kind: SpaceKind
    let title: String
    let account: AccountInfo?
    var size: CGFloat = 28

    var body: some View {
        picture
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                AccountBadge(info: account, size: 14)
                    .padding(1.5)
                    .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                    .offset(x: 6, y: 6)
            }
            .padding(.trailing, 2)
    }

    /// The sidebar's picture for the conversation, so a chat looks the same in both places.
    private var picture: some View {
        SpaceAvatar(title: title, kind: kind, size: size)
    }
}
