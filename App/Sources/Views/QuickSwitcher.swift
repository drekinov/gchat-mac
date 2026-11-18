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
            TextField("Jump to a conversation", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
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
            Divider()
            if entries.isEmpty {
                Text("No matching conversations").foregroundStyle(.secondary).padding(20)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        row(entry, selected: index == highlight)
                            .contentShape(Rectangle())
                            .onTapGesture { open(entries, index) }
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 500)
        .onChange(of: query) { highlight = 0 }
        .onExitCommand(perform: onClose)
        .task { focused = true }
    }

    private func row(_ entry: InboxEntry, selected: Bool) -> some View {
        HStack(spacing: 8) {
            AccountBadge(info: model.info(entry.account), size: 18)
            SpaceIcon(kind: model.kind(of: entry))
            Text(RemoteText.title(entry.summary.title)).lineLimit(1)
            Spacer()
            if entry.hasUnread { UnreadPill(count: entry.unread) }
            Text(model.info(entry.account)?.name ?? "").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func open(_ entries: [InboxEntry], _ index: Int) {
        guard entries.indices.contains(index) else { return }
        model.select(entries[index].id)
        onClose()
    }
}
