import ChatModel
import ChatSync
import SwiftUI

struct SidebarView: View {
    let model: AppModel
    @Environment(\.isSnapshotMode) private var snapshotMode

    var body: some View {
        VStack(spacing: 0) {
            AccountFilterBar(model: model)
            Divider()
            inboxList
            AccountStatusFooter(model: model)
        }
    }

    @ViewBuilder
    private var inboxList: some View {
        let entries = model.inbox
        let list = List(selection: selection) {
            ForEach(entries) { entry in
                InboxRow(
                    entry: entry, account: model.info(entry.account), kind: model.kind(of: entry),
                    showsBadge: model.accountFilter == nil
                )
                .tag(entry.id)
            }
        }
        .overlay {
            if entries.isEmpty { ProgressView().controlSize(.small) }
        }
        if snapshotMode {
            list.listStyle(.inset)
        } else {
            list.listStyle(.sidebar)
        }
    }

    private var selection: Binding<SpaceKey?> {
        Binding(get: { model.selection }, set: { model.select($0) })
    }
}

struct AccountFilterBar: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(
                    title: "All", info: nil, unread: model.unreadTotal, selected: model.accountFilter == nil,
                    showsTitle: true
                ) {
                    model.accountFilter = nil
                }
                ForEach(model.accounts) { info in
                    let selected = model.accountFilter == info.id
                    chip(
                        title: info.name, info: info, unread: model.unreadCount(for: info.id), selected: selected,
                        showsTitle: selected || !crowded
                    ) {
                        model.accountFilter = info.id
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    /// With many accounts only the selected chip keeps its name, so the row still fits.
    private var crowded: Bool { model.accounts.count > 3 }

    private func chip(
        title: String, info: AccountInfo?, unread: Int, selected: Bool, showsTitle: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let info { AccountBadge(info: info, size: 14) }
                if showsTitle { Text(RemoteText.title(title)).font(.callout.weight(selected ? .semibold : .regular)) }
                if unread > 0 {
                    Text(unread > 99 ? "99+" : "\(unread)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(info?.email.map { "\(title) — \($0)" } ?? title)
        .accessibilityLabel(unread > 0 ? "\(title), \(unread) unread" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct InboxRow: View {
    let entry: InboxEntry
    let account: AccountInfo?
    let kind: SpaceKind
    let showsBadge: Bool
    @AppStorage("sidebarDensity") private var density = SidebarDensity.comfortable

    var body: some View {
        let summary = entry.summary
        let unread = entry.unread
        HStack(alignment: .top, spacing: 8) {
            if showsBadge { AccountBadge(info: account, size: 18).padding(.top, 1) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    SpaceIcon(kind: kind)
                    Text(RemoteText.title(summary.title))
                        .font(.body.weight(entry.hasUnread ? .bold : .regular))
                        .lineLimit(1)
                    if entry.isMuted {
                        Image(systemName: "bell.slash.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                            .accessibilityLabel("Muted")
                    }
                    Spacer(minLength: 4)
                    if density == .compact && entry.hasUnread { UnreadPill(count: unread) }
                    Text(TimeFormat.relative(summary.lastActiveTime))
                        .font(.caption)
                        .foregroundStyle(entry.hasUnread ? Color.accentColor : .secondary)
                }
                if density == .comfortable {
                    HStack(spacing: 6) {
                        let preview = RemoteText.preview(summary.lastMessagePreview ?? "")
                        Text(
                            preview.isEmpty
                                ? (summary.lastMessagePreview == nil ? "No messages yet" : "No text") : preview
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        Spacer(minLength: 4)
                        if entry.hasUnread { UnreadPill(count: unread) }
                    }
                }
            }
        }
        .padding(.vertical, density == .compact ? 0 : 3)
    }
}

struct AccountStatusFooter: View {
    let model: AppModel

    var body: some View {
        let problems = model.accounts.compactMap { info -> (AccountInfo, String)? in
            model.status(info.id).warning.map { (info, $0) }
        }
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                ForEach(problems, id: \.0.id) { info, message in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        AccountChip(info: info)
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
}
