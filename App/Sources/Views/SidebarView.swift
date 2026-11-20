import ChatModel
import ChatSync
import SwiftUI

struct SidebarView: View {
    let model: AppModel
    @AppStorage("sidebarDensity") private var density = SidebarDensity.comfortable
    @State private var query = ""
    @State private var hovered: SpaceKey?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(model: model, query: $query)
            inboxList
            AccountStatusFooter(model: model)
        }
    }

    /// A plain scrolling stack rather than a sidebar List, so the selected chat gets the design's soft tint instead
    /// of the system's strong highlight. Clicking a chat focuses the list; the arrow keys then move the selection,
    /// as in a sidebar.
    private var inboxList: some View {
        let entries = filtered(model.inbox)
        let spaces = entries.filter { model.kind(of: $0) == .space }
        let people = entries.filter { model.kind(of: $0) != .space }
        let ordered = spaces + people
        // Badges only help when chats from several accounts share the list.
        let showsBadges = model.accountFilter == nil && model.accounts.count > 1
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !spaces.isEmpty {
                        header("Spaces")
                        rows(spaces, showsBadges: showsBadges)
                    }
                    if !people.isEmpty {
                        header("Direct messages").padding(.top, spaces.isEmpty ? 0 : 8)
                        rows(people, showsBadges: showsBadges)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1, in: ordered) }
            .onKeyPress(.downArrow) { move(1, in: ordered) }
            .onChange(of: model.selection) { _, key in
                guard let key, listFocused else { return }
                proxy.scrollTo(key)
            }
            .overlay {
                if model.inbox.isEmpty {
                    ProgressView().controlSize(.small)
                } else if entries.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func rows(_ entries: [InboxEntry], showsBadges: Bool) -> some View {
        ForEach(entries) { entry in
            let selected = model.selection == entry.id
            Button {
                listFocused = true
                model.select(entry.id)
            } label: {
                InboxRow(
                    entry: entry, account: model.info(entry.account), kind: model.kind(of: entry),
                    showsBadge: showsBadges, isSelected: selected, density: density,
                    faces: model.spaceFaces[entry.id], media: model.mediaLoader(for: entry.account),
                    photoURL: { model.photoURL($0, account: entry.account) }
                )
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background(selected: selected, hovered: hovered == entry.id), in: Card())
                .contentShape(Card())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside {
                    hovered = entry.id
                } else if hovered == entry.id {
                    hovered = nil
                }
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .id(entry.id)
        }
    }

    private func background(selected: Bool, hovered: Bool) -> Color {
        if selected { return Theme.selection }
        return hovered ? Color.primary.opacity(0.04) : .clear
    }

    private func move(_ step: Int, in entries: [InboxEntry]) -> KeyPress.Result {
        guard !entries.isEmpty else { return .ignored }
        let current = entries.firstIndex { $0.id == model.selection }
        let next = current.map { min(max($0 + step, 0), entries.count - 1) } ?? (step > 0 ? 0 : entries.count - 1)
        model.select(entries[next].id)
        return .handled
    }

    private func filtered(_ entries: [InboxEntry]) -> [InboxEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return entries }
        return entries.filter { RemoteText.title($0.summary.title).localizedCaseInsensitiveContains(needle) }
    }
}

/// The rounded shape behind a chat in the sidebar.
private struct Card: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: 12, style: .continuous).path(in: rect)
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

/// Account badges drawn as images for places that only take an image, such as a menu button. They're drawn with
/// AppKit: SwiftUI's ImageRenderer would start an offscreen renderer that briefly costs tens of megabytes.
@MainActor
enum BadgeImages {
    private static var cache: [String: NSImage] = [:]

    static func image(for account: AccountInfo?, all accounts: [AccountInfo]) -> NSImage? {
        if let account {
            let letter = AccountBadge.letter(account.name)
            return cached("\(account.colorIndex)|\(letter)") { badge(letter, color(account.colorIndex)) }
        }
        let indexes = accounts.prefix(2).map(\.colorIndex)
        return cached("all|" + indexes.map(String.init).joined(separator: ",")) { dots(indexes.map(color)) }
    }

    private static func color(_ index: Int) -> NSColor { NSColor(AccountPalette.color(index)) }

    private static func cached(_ key: String, _ make: () -> NSImage) -> NSImage {
        if let hit = cache[key] { return hit }
        let image = make()
        cache[key] = image
        return image
    }

    private static func badge(_ letter: String, _ fill: NSColor, size: CGFloat = 14) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size * 0.56, weight: .heavy), .foregroundColor: NSColor.white,
            ]
            let text = letter as NSString
            let measured = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: rect.midX - measured.width / 2, y: rect.midY - measured.height / 2),
                withAttributes: attributes)
            return true
        }
    }

    private static func dots(_ fills: [NSColor], size: CGFloat = 9) -> NSImage {
        let width = size + CGFloat(max(fills.count - 1, 0)) * (size - 3)
        return NSImage(size: NSSize(width: width, height: size), flipped: false) { _ in
            for (index, fill) in fills.enumerated() {
                fill.setFill()
                NSBezierPath(ovalIn: NSRect(x: CGFloat(index) * (size - 3), y: 0, width: size, height: size)).fill()
            }
            return true
        }
    }
}

struct InboxRow: View {
    let entry: InboxEntry
    let account: AccountInfo?
    let kind: SpaceKind
    let showsBadge: Bool
    let isSelected: Bool
    var density = SidebarDensity.comfortable
    /// Two members, drawn overlapping in place of a space's letter once its member list is cached.
    var faces: [User]?
    var media: MediaLoader?
    var photoURL: (UserName) -> URL? = { _ in nil }

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
        picture(title, size: size)
            .overlay(alignment: .bottomTrailing) {
                if showsBadge {
                    AccountBadge(info: account, size: size > 30 ? 16 : 13)
                        .padding(1.5)
                        .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                        .offset(x: 4, y: 4)
                }
            }
    }

    @ViewBuilder
    private func picture(_ title: String, size: CGFloat) -> some View {
        if let faces, faces.count >= 2, kind == .space || kind == .group {
            FaceStack(users: faces, media: media, photoURL: photoURL, size: size)
        } else {
            SpaceAvatar(title: title, kind: kind, size: size)
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

/// Two people's pictures, one up and to the left, the other overlapping it down and to the right.
struct FaceStack: View {
    let users: [User]
    var media: MediaLoader?
    var photoURL: (UserName) -> URL?
    var size: CGFloat = 38

    var body: some View {
        let small = (size * 0.66).rounded()
        ZStack {
            face(users[0], small)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            face(users[1], small)
                .padding(1.5)
                .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func face(_ user: User, _ size: CGFloat) -> some View {
        PhotoAvatar(
            name: RemoteText.title(user.displayName ?? ""), url: photoURL(user.name), media: media, size: size)
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
