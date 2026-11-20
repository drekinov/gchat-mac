import ChatModel
import ChatSync
import SwiftUI

struct SidebarView: View {
    let model: AppModel
    @Environment(\.isSnapshotMode) private var snapshotMode
    @AppStorage("sidebarDensity") private var density = SidebarDensity.comfortable
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(model: model, query: $query)
            inboxList
            AccountStatusFooter(model: model)
        }
    }

    @ViewBuilder
    private var inboxList: some View {
        let entries = filtered(model.inbox)
        let spaces = entries.filter { model.kind(of: $0) == .space }
        let people = entries.filter { model.kind(of: $0) != .space }
        // Badges only help when chats from several accounts share the list.
        let showsBadges = model.accountFilter == nil && model.accounts.count > 1
        let list = List(selection: selection) {
            if !spaces.isEmpty {
                Section("Spaces") { rows(spaces, showsBadges: showsBadges) }
            }
            if !people.isEmpty {
                Section("Direct messages") { rows(people, showsBadges: showsBadges) }
            }
        }
        .overlay {
            if model.inbox.isEmpty {
                ProgressView().controlSize(.small)
            } else if entries.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        if snapshotMode {
            list.listStyle(.inset)
        } else {
            list.listStyle(.sidebar)
        }
    }

    private func rows(_ entries: [InboxEntry], showsBadges: Bool) -> some View {
        ForEach(entries) { entry in
            InboxRow(
                entry: entry, account: model.info(entry.account), kind: model.kind(of: entry),
                showsBadge: showsBadges, isSelected: model.selection == entry.id, density: density
            )
            .tag(entry.id)
        }
    }

    private func filtered(_ entries: [InboxEntry]) -> [InboxEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return entries }
        return entries.filter { RemoteText.title($0.summary.title).localizedCaseInsensitiveContains(needle) }
    }

    private var selection: Binding<SpaceKey?> {
        Binding(get: { model.selection }, set: { model.select($0) })
    }
}

/// The search field that filters the list, and the menu that picks which account's chats it shows.
struct SidebarHeader: View {
    let model: AppModel
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            SidebarSearchField(text: $query)
            if model.accounts.count > 1 { AccountMenu(model: model) }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

struct SidebarSearchField: View {
    @Binding var text: String
    var prompt = "Search"

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct AccountMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Picker("Show conversations from", selection: $model.accountFilter) {
                Text(item("All accounts", unread: model.unreadTotal)).tag(AccountID?.none)
                ForEach(model.accounts) { info in
                    Text(item(RemoteText.title(info.name), unread: model.unreadCount(for: info.id)))
                        .tag(AccountID?.some(info.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            // A menu button draws only a title and an image, so the badge goes in as a rendered image.
            let current = model.accountFilter.flatMap { model.info($0) }
            Label {
                Text(current.map { RemoteText.title($0.name) } ?? "All").lineLimit(1)
            } icon: {
                if let icon = BadgeImages.image(for: current, all: model.accounts) {
                    Image(nsImage: icon)
                }
            }
            .labelStyle(.titleAndIcon)
            .font(.callout.weight(.medium))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .help("Show conversations from all accounts or one (Option-Command-0, 1, 2…)")
    }

    private func item(_ name: String, unread: Int) -> String {
        unread > 0 ? "\(name) (\(unread))" : name
    }
}

/// Account badges rendered to images for places that only take an image, such as a menu button. Cached, since
/// the menu's label is rebuilt whenever unread counts change.
@MainActor
enum BadgeImages {
    private static var cache: [String: NSImage] = [:]

    static func image(for account: AccountInfo?, all accounts: [AccountInfo]) -> NSImage? {
        if let account {
            let key = "\(account.colorIndex)|\(AccountBadge.letter(account.name))"
            return cached(key) { AccountBadge(info: account, size: 14) }
        }
        let key = "all|" + accounts.prefix(2).map { "\($0.colorIndex)" }.joined(separator: ",")
        return cached(key) { AccountDots(accounts: accounts) }
    }

    private static func cached<V: View>(_ key: String, _ view: () -> V) -> NSImage? {
        if let hit = cache[key] { return hit }
        let renderer = ImageRenderer(content: view())
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = false
        cache[key] = image
        return image
    }
}

/// Two overlapping account colours: the "all accounts" mark.
struct AccountDots: View {
    let accounts: [AccountInfo]

    var body: some View {
        HStack(spacing: -3) {
            ForEach(accounts.prefix(2)) { info in
                Circle().fill(AccountPalette.color(info.colorIndex)).frame(width: 9, height: 9)
            }
        }
        .accessibilityHidden(true)
    }
}

struct InboxRow: View {
    let entry: InboxEntry
    let account: AccountInfo?
    let kind: SpaceKind
    let showsBadge: Bool
    let isSelected: Bool
    var density = SidebarDensity.comfortable

    var body: some View {
        let summary = entry.summary
        let title = RemoteText.title(summary.title)
        let compact = density == .compact
        HStack(spacing: 8) {
            // The open conversation is being read, so its dot would only flicker before the count clears.
            Circle()
                .fill(entry.hasUnread && !isSelected ? Theme.accent : .clear)
                .frame(width: 7, height: 7)
            avatar(title, size: compact ? 24 : 38)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(title)
                        .font(.body.weight(entry.hasUnread ? .semibold : .medium))
                        .lineLimit(1)
                    if entry.isMuted {
                        Image(systemName: "bell.slash.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if compact && entry.hasUnread { UnreadPill(count: entry.unread) }
                    Text(TimeFormat.relative(summary.lastActiveTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !compact {
                    Text(preview(summary))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, compact ? 1 : 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(title))
        .help(showsBadge ? "\(title) in \(RemoteText.title(account?.name ?? ""))" : title)
    }

    private func avatar(_ title: String, size: CGFloat) -> some View {
        SpaceAvatar(title: title, kind: kind, size: size)
            .overlay(alignment: .bottomTrailing) {
                if showsBadge {
                    AccountBadge(info: account, size: size > 30 ? 16 : 13)
                        .padding(1.5)
                        .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                        .offset(x: 4, y: 4)
                }
            }
    }

    private func preview(_ summary: SpaceSummary) -> String {
        let preview = RemoteText.preview(summary.lastMessagePreview ?? "")
        if !preview.isEmpty { return preview }
        return summary.lastMessagePreview == nil ? "No messages yet" : "No text"
    }

    private func accessibilityText(_ title: String) -> String {
        var parts = [title]
        if showsBadge, let account { parts.append("\(RemoteText.title(account.name)) account") }
        if entry.hasUnread { parts.append("\(entry.unread) unread") }
        if entry.isMuted { parts.append("muted") }
        return parts.joined(separator: ", ")
    }
}

/// Accounts that need attention, at the bottom of the sidebar. Signing in again is one click away.
struct AccountStatusFooter: View {
    let model: AppModel

    var body: some View {
        let problems = model.accounts.compactMap { info -> (AccountInfo, AccountStatus, String)? in
            let status = model.status(info.id)
            return status.warning.map { (info, status, $0) }
        }
        if !problems.isEmpty {
            VStack(spacing: 6) {
                ForEach(problems, id: \.0.id) { info, status, message in
                    HStack(alignment: .top, spacing: 8) {
                        AccountBadge(info: info, size: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(RemoteText.title(info.name)).font(.callout.weight(.semibold))
                            Text(message).font(.caption).foregroundStyle(.secondary)
                            if case .needsLogin = status, model.live != nil {
                                Button("Sign in again") { model.startReconnect(info) }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                    .disabled(model.isSigningIn)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                            .accessibilityHidden(true)
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
    }
}
