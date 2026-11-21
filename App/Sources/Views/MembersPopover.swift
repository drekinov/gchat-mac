import ChatModel
import ChatSync
import SwiftUI

/// Everyone in the conversation, from the members list the app caches: you first, then owners and managers, members,
/// apps and deleted users. Message opens a direct message; Mention adds them to the reply.
struct MembersPopover: View {
    let model: AppModel
    let key: SpaceKey
    let members: [Membership]
    var onClose: () -> Void
    @State private var query = ""
    @State private var hovered: UserName?
    @State private var failure: String?
    /// Nil while the cache is being checked or fetched; false when the members couldn't be fetched.
    @State private var fetched: Bool?

    var body: some View {
        let summary = model.summary(for: key)
        let shown = filtered(sorted)
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text(RemoteText.title(summary?.title ?? "")).font(.headline).lineLimit(1)
                HStack(spacing: 5) {
                    AccountBadge(info: model.info(key.account), size: 13)
                    Text(subtitle(summary)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 10)
            .padding(.horizontal, 16)

            SidebarSearchField(text: $query, prompt: "Find a member")
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if members.isEmpty {
                emptyState
            } else if shown.isEmpty {
                Text("No members match “\(query)”.").font(.callout).foregroundStyle(.secondary).padding(20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(shown, id: \.name) { membership in row(membership) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 380)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(Theme.error).padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
        .frame(width: 340)
        .task { await load() }
    }

    @ViewBuilder private var emptyState: some View {
        switch fetched {
        case nil:
            Text("Loading members…").font(.callout).foregroundStyle(.secondary).padding(20)
        case true?:
            Text("No members").font(.callout).foregroundStyle(.secondary).padding(20)
        case false?:
            VStack(spacing: 6) {
                Text("Couldn't load members").font(.callout).foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }.buttonStyle(.link)
            }
            .padding(20)
        }
    }

    private func load() async {
        fetched = nil
        fetched = await model.ensureMembers(for: key)
    }

    private var me: UserName? { model.info(key.account)?.me }

    private func subtitle(_ summary: SpaceSummary?) -> String {
        let joined = members.filter { $0.state == .joined }.count
        let account = RemoteText.title(model.info(key.account)?.name ?? "")
        let people = "\(joined) \(joined == 1 ? "member" : "members")"
        switch summary?.type {
        case .directMessage: return account
        case .groupChat: return "\(account) group chat with \(people)"
        default: return "\(account) space with \(people)"
        }
    }

    /// You, owners and managers, members, apps, then deleted users; by name within each.
    private var sorted: [Membership] {
        func rank(_ m: Membership) -> Int {
            if m.member.name == me { return 0 }
            if m.member.isAnonymous { return 4 }
            if m.member.type == .bot { return 3 }
            return role(m) == nil ? 2 : 1
        }
        return members.filter { $0.state == .joined }.sorted {
            let (a, b) = (rank($0), rank($1))
            if a != b { return a < b }
            return name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending
        }
    }

    private func filtered(_ list: [Membership]) -> [Membership] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return list }
        return list.filter { name($0).localizedCaseInsensitiveContains(needle) }
    }

    private func name(_ membership: Membership) -> String {
        if membership.member.isAnonymous { return "Deleted user" }
        let name = RemoteText.title(membership.member.displayName ?? "")
        return name.isEmpty ? "Unknown" : name
    }

    private func detail(_ membership: Membership) -> String? {
        if membership.member.isAnonymous { return nil }
        if membership.member.type == .bot { return "App" }
        return nil
    }

    /// Chat's API calls a space's owners managers, and its managers assistant managers.
    private func role(_ membership: Membership) -> String? {
        switch membership.role {
        case .manager: "Owner"
        case .assistantManager: "Manager"
        case .member, .unspecified: nil
        }
    }

    /// People you can message or mention: joined, human, not deleted, and not you.
    private func reachable(_ membership: Membership) -> Bool {
        membership.state == .joined && membership.member.type == .human && !membership.member.isAnonymous
            && membership.member.name != me
    }

    private func row(_ membership: Membership) -> some View {
        let user = membership.member.name
        let isMe = user == me
        let canReach = reachable(membership)
        let showsActions = canReach && hovered == user
        let label = name(membership) + (isMe ? " (you)" : "")
        return HStack(spacing: 10) {
            if membership.member.type == .bot {
                SpaceAvatar(title: label, kind: .bot, size: 30)
            } else {
                PhotoAvatar(
                    name: label, url: model.photoURL(user, account: key.account),
                    media: model.mediaLoader(for: key.account), size: 30)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if let detail = detail(membership) {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if showsActions {
                Button {
                    message(membership)
                } label: {
                    Image(systemName: "bubble.left.fill").font(.system(size: 12))
                        .frame(width: 26, height: 26)
                        .background(Theme.accent, in: Circle())
                        .foregroundStyle(Theme.onAccent)
                }
                .buttonStyle(.plain)
                .help("Message \(label)")
                Button {
                    mention(membership)
                } label: {
                    Image(systemName: "at").font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Mention \(label) in the reply")
            } else if let role = role(membership) {
                Text(role).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(hovered == user ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hovered = user
            } else if hovered == user {
                hovered = nil
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Message") { if canReach { message(membership) } }
        .accessibilityAction(named: "Mention") { if canReach { mention(membership) } }
    }

    private func contact(_ membership: Membership) -> Contact {
        Contact(
            user: membership.member.name, displayName: membership.member.displayName ?? "", email: nil,
            directMessage: nil, source: .chats)
    }

    private func message(_ membership: Membership) {
        let contact = contact(membership)
        Task {
            failure = await model.startDirectMessage(contact, account: key.account)
            if failure == nil { onClose() }
        }
    }

    private func mention(_ membership: Membership) {
        model.requestMention(contact(membership), in: ComposerID(key: key, thread: nil))
        onClose()
    }
}
