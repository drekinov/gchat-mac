import ChatModel
import ChatStore
import ChatSync
import SwiftUI

/// What the app knows about a conversation, from its stored record: when it was made and last active, how replies
/// work, its history setting, whether guests can join and its notification setting. The title opens the members.
struct ConversationDetailsPopover: View {
    let model: AppModel
    let key: SpaceKey
    let members: [Membership]
    @State private var stored: StoredSpace?

    var body: some View {
        let summary = model.summary(for: key)
        VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text(RemoteText.title(summary?.title ?? "")).font(.headline).lineLimit(1)
                HStack(spacing: 5) {
                    AccountBadge(info: model.info(key.account), size: 13)
                    Text(subtitle(summary)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 14)
            .padding(.bottom, 12)
            .padding(.horizontal, 16)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 9) {
                ForEach(rows(summary), id: \.label) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(row.value).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 340)
        .task(id: key) { stored = await model.storedSpace(for: key) }
    }

    private struct Row {
        let label: String
        let value: String
    }

    private func rows(_ summary: SpaceSummary?) -> [Row] {
        var rows: [Row] = []
        let space = stored?.space
        if let created = space?.createTime {
            rows.append(Row(label: "Created", value: created.date.formatted(date: .abbreviated, time: .omitted)))
        }
        if let active = summary?.lastActiveTime ?? space?.lastActiveTime {
            let date = active.date
            let value =
                Calendar.current.isDateInToday(date)
                ? "Today \(date.formatted(.dateTime.hour().minute()))" : TimeFormat.message(active)
            rows.append(Row(label: "Last active", value: value))
        }
        if let summary {
            rows.append(Row(label: "Replies", value: summary.isThreaded ? "In threads" : "In the conversation"))
        }
        if let historyOn = summary?.historyOn ?? space?.historyOn {
            rows.append(
                Row(
                    label: "History",
                    value: historyOn
                        ? "On, kept by your organization's rules" : "Off, deleted after about 24 hours"))
        }
        if let space, space.type == .space {
            rows.append(
                Row(
                    label: "Guests",
                    value: space.isExternalUserAllowed
                        ? "People outside your organization can join" : "Only your organization"))
        }
        if let setting = stored?.notificationSetting {
            let level =
                switch setting.level {
                case .all: "All messages"
                case .mainConversations: "Main conversations"
                case .forYou: "Mentions and followed threads"
                case .off: "Off"
                }
            rows.append(Row(label: "Notifications", value: setting.isMuted ? "\(level), muted" : level))
        }
        return rows
    }

    private func subtitle(_ summary: SpaceSummary?) -> String {
        let account = RemoteText.title(model.info(key.account)?.name ?? "")
        let joined = members.filter { $0.state == .joined }.count
        let people = joined > 0 ? " with \(joined) \(joined == 1 ? "member" : "members")" : ""
        switch summary?.type {
        case .directMessage: return "\(account) direct message"
        case .groupChat: return "\(account) group chat\(people)"
        default: return "\(account) space\(people)"
        }
    }
}
