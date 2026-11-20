import ChatModel
import ChatSync
import GoogleChat
import SwiftUI

struct ReactionActions {
    var canReact: Bool
    var isMine: @MainActor (Emoji, MessageName) -> Bool
    var toggle: @MainActor (Emoji, MessageName) -> Void
    var customEmojis: @MainActor () -> [CustomEmoji]
}

private struct ForcedHoverKey: EnvironmentKey {
    static let defaultValue: MessageName? = nil
}

extension EnvironmentValues {
    /// Snapshot mode pins the hover action bar to one message.
    var forcedHoverMessage: MessageName? {
        get { self[ForcedHoverKey.self] }
        set { self[ForcedHoverKey.self] = newValue }
    }
}

/// What a row needs from the rest of the open conversation: who "me" is, and a way to resolve quoted messages.
struct MessageContext {
    var me: UserName?
    var messages: [MessageName: Message] = [:]
    var names: [UserName: String] = [:]
    var actions: ReactionActions?
    var media: MediaLoader?
    var openPreview: (Attachment) -> Void = { _ in }
    var openGifPreview: (URL) -> Void = { _ in }
    var photoURL: (UserName) -> URL? = { _ in nil }
    /// Names above other people's bubbles; off in a direct message, where there's only one other person.
    var showsSenderNames = true
    var showsAvatars = true

    init(me: UserName?, messages: [Message]) {
        self.me = me
        for message in messages {
            self.messages[message.name] = message
            if let name = message.sender.displayName, !name.isEmpty { names[message.sender.name] = name }
        }
    }

    func quote(_ quoted: QuotedMessage) -> (sender: String, text: String) {
        let original = messages[quoted.name]
        let text = quoted.snapshotText ?? (original?.isDeleted == false ? original?.text : nil) ?? ""
        let sender = quoted.snapshotSender.flatMap { names[$0] } ?? original?.sender.displayName ?? "Unknown"
        return (RemoteText.title(sender), RemoteText.message(text))
    }
}

@MainActor
enum MessageRendering {
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// `onAccent` is for text on an accent-coloured bubble, where mentions and links turn white.
    static func attributed(_ message: Message, me: UserName?, onAccent: Bool = false) -> AttributedString {
        let raw = message.text
        let clean = RemoteText.message(raw)
        var result = AttributedString(clean)
        if clean == raw { styleAnnotations(of: message, raw: raw, me: me, onAccent: onAccent, in: &result) }
        linkify(clean, underlined: onAccent, in: &result)
        return result
    }

    static func linkified(_ raw: String) -> AttributedString {
        let clean = RemoteText.message(raw)
        var result = AttributedString(clean)
        linkify(clean, underlined: false, in: &result)
        return result
    }

    private static func styleAnnotations(
        of message: Message, raw: String, me: UserName?, onAccent: Bool, in result: inout AttributedString
    ) {
        let utf16 = raw.utf16
        for annotation in message.annotations {
            guard annotation.startIndex >= 0, annotation.length > 0,
                annotation.startIndex + annotation.length <= utf16.count
            else { continue }
            let start = utf16.index(utf16.startIndex, offsetBy: annotation.startIndex)
            let end = utf16.index(start, offsetBy: annotation.length)
            guard let lower = String.Index(start, within: raw), let upper = String.Index(end, within: raw),
                let from = AttributedString.Index(lower, within: result),
                let to = AttributedString.Index(upper, within: result)
            else { continue }
            switch annotation.kind {
            case .userMention(let user):
                result[from..<to].font = .body.weight(.semibold)
                result[from..<to].foregroundColor = onAccent ? Theme.onAccent : Theme.accentText
                if user == me || user == .all {
                    result[from..<to].backgroundColor = onAccent ? Color.white.opacity(0.22) : Theme.selection
                }
            case .customEmoji:
                result[from..<to].font = .body.monospaced()
                if !onAccent {
                    result[from..<to].foregroundColor = Color(red: 0.50, green: 0.30, blue: 0.80)
                    result[from..<to].backgroundColor = Color(red: 0.50, green: 0.30, blue: 0.80).opacity(0.12)
                }
            case .slashCommand, .richLink:
                continue
            }
        }
    }

    private static func linkify(_ text: String, underlined: Bool, in result: inout AttributedString) {
        guard let detector = linkDetector, text.utf8.count < 20_000 else { return }
        let whole = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: whole) {
            guard let url = match.url, url.scheme?.lowercased() == "https", url.host() != nil,
                let range = Range(match.range, in: text),
                let from = AttributedString.Index(range.lowerBound, within: result),
                let to = AttributedString.Index(range.upperBound, within: result)
            else { continue }
            result[from..<to].link = url
            if underlined { result[from..<to].underlineStyle = .single }
        }
    }
}

struct MessageRowModel: Identifiable {
    let message: Message
    let showsHeader: Bool
    let replies: Int
    /// The last message of a run from one sender, where the avatar sits.
    var endsGroup = true
    /// A time shown above the row: at the start, on a new day, and after a pause.
    var timeHeader: Timestamp?
    /// The thread's latest reply and the latest people to reply, for the replies button.
    var lastReply: Message?
    var repliers: [User] = []

    var id: MessageName { message.id }

    static func build(_ messages: [Message], threaded: Bool, showsReplies: Bool) -> [MessageRowModel] {
        var counts: [ThreadName: Int] = [:]
        var latest: [ThreadName: Message] = [:]
        var people: [ThreadName: [User]] = [:]
        if showsReplies {
            for message in messages where message.isThreadReply && !message.isDeleted {
                guard let thread = message.thread else { continue }
                counts[thread, default: 0] += 1
                latest[thread] = message
                var seen = people[thread, default: []].filter { $0.name != message.sender.name }
                seen.append(message.sender)
                people[thread] = Array(seen.suffix(2))
            }
        }
        let visible = threaded && showsReplies ? messages.filter { !$0.isThreadReply } : messages
        var rows: [MessageRowModel] = []
        for message in visible {
            let replies = message.thread.flatMap { counts[$0] } ?? 0
            var header = true
            if let last = rows.last, !last.message.isDeleted, !message.isDeleted, last.replies == 0,
                last.message.sender.name == message.sender.name, !last.message.hasRichContent,
                message.createTime.date.timeIntervalSince(last.message.createTime.date) < 300
            {
                header = false
            }
            var row = MessageRowModel(message: message, showsHeader: header, replies: replies)
            if replies > 0, let thread = message.thread {
                row.lastReply = latest[thread]
                row.repliers = people[thread] ?? []
            }
            let previous = rows.last?.message.createTime.date
            let date = message.createTime.date
            if previous.map({ !Calendar.current.isDate($0, inSameDayAs: date) || date.timeIntervalSince($0) > 1800 })
                ?? true
            {
                row.timeHeader = message.createTime
            }
            rows.append(row)
        }
        for index in rows.indices.dropLast() {
            rows[index].endsGroup = rows[index + 1].showsHeader || rows[index + 1].timeHeader != nil
        }
        return rows
    }
}

extension Message {
    var hasRichContent: Bool {
        !attachments.isEmpty || !gifURLs.isEmpty || !reactions.isEmpty || quoted != nil || cardsFallbackText != nil
            || cards != nil
    }
}

/// A centred time between messages, like "Today 10:02".
struct TimeHeader: View {
    let time: Timestamp

    var body: some View {
        let date = time.date
        let text =
            Calendar.current.isDateInToday(date)
            ? "Today \(date.formatted(.dateTime.hour().minute()))" : TimeFormat.message(time)
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

/// One message as a bubble: other people's on the left in grey, mine on the right in the accent colour.
struct MessageRow: View {
    let row: MessageRowModel
    let context: MessageContext
    var onOpenThread: ((ThreadName) -> Void)?
    /// This message's thread is open below it.
    var threadOpen = false
    /// Inside an open thread: smaller avatars and no thread button.
    var compact = false
    @State private var hovering = false
    @State private var pickerOpen = false
    @Environment(\.forcedHoverMessage) private var forcedHover

    private var isMine: Bool { context.me != nil && row.message.sender.name == context.me }
    private var avatarSize: CGFloat { compact ? 22 : 28 }

    var body: some View {
        let message = row.message
        let mine = isMine
        let showsBar = !message.isDeleted && (hovering || pickerOpen || forcedHover == message.name)
        let indent: CGFloat = !mine && context.showsAvatars ? avatarSize + 8 : 0
        VStack(spacing: 2) {
            if let time = row.timeHeader { TimeHeader(time: time) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                if row.showsHeader && !mine && context.showsSenderNames {
                    senderLine(message).padding(.leading, indent + 12)
                }
                // The avatar lines up with the bubble's last line; reactions and replies sit underneath.
                HStack(alignment: .bottom, spacing: 8) {
                    if mine {
                        Spacer(minLength: 56)
                    } else if context.showsAvatars {
                        avatar
                    }
                    bubbleStack(message, mine: mine, showsBar: showsBar)
                    if !mine { Spacer(minLength: 56) }
                }
                extras(message, mine: mine).padding(.leading, indent)
            }
        }
        .padding(.top, row.showsHeader ? 6 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var avatar: some View {
        if row.endsGroup {
            PhotoAvatar(
                name: senderName, url: context.photoURL(row.message.sender.name), media: context.media,
                size: avatarSize)
        } else {
            Color.clear.frame(width: avatarSize, height: 1)
        }
    }

    private func senderLine(_ message: Message) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(senderName).font(.caption.weight(.medium))
            if message.sender.type == .bot {
                Text("App").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4)
                    .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
            }
            // The time separator above already says when, so the time repeats only without one.
            if row.timeHeader == nil {
                Text(message.createTime.date.formatted(.dateTime.hour().minute()))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
    }

    /// The bubble and what belongs to it: cards, GIFs and attachments.
    @ViewBuilder
    private func bubbleStack(_ message: Message, mine: Bool, showsBar: Bool) -> some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            if message.isDeleted {
                Text("Message deleted").italic().foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .overlay(Bubble().strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(dash: [4])))
            } else {
                liveContent(message, mine: mine)
            }
        }
        // The actions sit just outside the bubble, so they attach before the width limit widens the stack.
        .overlay(alignment: mine ? .topLeading : .topTrailing) {
            if showsBar {
                actionBar(message)
                    .alignmentGuide(mine ? .leading : .trailing) { mine ? $0[.trailing] + 6 : $0[.leading] - 6 }
            }
        }
        .frame(maxWidth: 580, alignment: mine ? .trailing : .leading)
    }

    /// Reactions and the replies button, under the bubble on the same side.
    @ViewBuilder
    private func extras(_ message: Message, mine: Bool) -> some View {
        let reactions = !message.isDeleted && !message.reactions.isEmpty
        let replies = row.replies > 0 && !compact && message.thread != nil && onOpenThread != nil
        if reactions || replies {
            VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
                if reactions {
                    ReactionPills(reactions: message.reactions, message: message.name, actions: context.actions)
                }
                if replies, let thread = message.thread, let onOpenThread {
                    RepliesButton(row: row, context: context, open: threadOpen) { onOpenThread(thread) }
                }
            }
            .frame(maxWidth: 580, alignment: mine ? .trailing : .leading)
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func liveContent(_ message: Message, mine: Bool) -> some View {
        let quote = message.quoted.map { context.quote($0) }
        if quote != nil || !message.text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let quote { QuotedBlock(sender: quote.sender, text: quote.text) }
                if !message.text.isEmpty {
                    Text(MessageRendering.attributed(message, me: context.me, onAccent: mine))
                        .textSelection(.enabled)
                        .tint(mine ? Theme.onAccent : Theme.accentText)
                        .padding(.horizontal, quote == nil ? 0 : 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(mine ? Theme.onAccent : Color(nsColor: .labelColor))
            .background(mine ? Theme.accent : Theme.incomingBubble, in: Bubble())
            .help(message.createTime.date.formatted(date: .complete, time: .shortened))
        }
        if let cards = message.cards {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in CardView(card: card) }
        } else if let fallback = message.cardsFallbackText {
            CardBox(text: RemoteText.message(fallback))
        }
        if let media = context.media {
            ForEach(message.gifURLs, id: \.self) { url in
                GifAttachmentView(url: url, media: media, onPreview: context.openGifPreview)
            }
        }
        if !message.attachments.isEmpty {
            FlowLayout(spacing: 8) {
                ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                    AttachmentView(attachment: attachment, media: context.media, onPreview: context.openPreview)
                }
            }
        }
    }

    private func actionBar(_ message: Message) -> some View {
        let enabled = context.actions?.canReact ?? false
        return HStack(spacing: 2) {
            Button {
                pickerOpen = true
            } label: {
                Image(systemName: "face.smiling").frame(width: 26, height: 24)
            }
            .help("Add reaction")
            .disabled(!enabled)
            .popover(isPresented: $pickerOpen, arrowEdge: .bottom) {
                EmojiPicker(customEmojis: context.actions?.customEmojis() ?? []) { pick in
                    context.actions?.toggle(pick.reaction, message.name)
                } onClose: {
                    pickerOpen = false
                }
            }
            if !compact, let thread = message.thread, let onOpenThread {
                Button {
                    onOpenThread(thread)
                } label: {
                    Image(systemName: "arrowshape.turn.up.left").frame(width: 26, height: 24)
                }
                .help("Reply in thread")
            }
        }
        .buttonStyle(.borderless)
        .padding(2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        .fixedSize()
    }

    private var senderName: String {
        let name = row.message.sender.displayName.map(RemoteText.title) ?? ""
        return name.isEmpty ? "Unknown" : name
    }
}

/// The shape every bubble shares.
struct Bubble: InsettableShape {
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: 17, style: .continuous).inset(by: inset).path(in: rect)
    }

    func inset(by amount: CGFloat) -> Bubble { Bubble(inset: inset + amount) }
}

/// "3 replies" under a message, with the latest people to reply and the latest reply; opens the thread in place.
struct RepliesButton: View {
    let row: MessageRowModel
    let context: MessageContext
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                HStack(spacing: -6) {
                    ForEach(row.repliers, id: \.name) { user in
                        let name = user.displayName.map(RemoteText.title) ?? ""
                        PhotoAvatar(name: name, url: context.photoURL(user.name), media: context.media, size: 18)
                            .padding(1.5)
                            .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                    }
                }
                Text(open ? "Hide replies" : "\(row.replies) \(row.replies == 1 ? "reply" : "replies")")
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.accentText)
                if !open, let reply = row.lastReply {
                    Text(preview(reply)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.callout)
            .padding(.leading, row.repliers.isEmpty ? 10 : 3)
            .padding(.trailing, 10)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.3)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(open ? "Hide the replies" : "Show the replies here")
        .accessibilityLabel(open ? "Hide replies" : "\(row.replies) replies, show them")
    }

    private func preview(_ reply: Message) -> String {
        let name = reply.sender.displayName.map(RemoteText.title)?.split(separator: " ").first.map(String.init) ?? ""
        let text = RemoteText.preview(reply.text)
        return name.isEmpty ? text : "\(name): \(text.isEmpty ? "Attachment" : text)"
    }
}

/// A quoted message inside a bubble. Its colours are fixed, so it reads the same on grey and accent bubbles.
struct QuotedBlock: View {
    let sender: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(sender).font(.caption.weight(.semibold)).foregroundStyle(Color(nsColor: .labelColor))
            Text(text.isEmpty ? "Original message unavailable" : text)
                .font(.callout)
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.insetSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Quoted message from \(sender)")
    }
}

struct CardBox: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Card", systemImage: "rectangle.on.rectangle").font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
        }
        .cardFrame()
    }
}

extension View {
    fileprivate func cardFrame() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: 420, alignment: .leading)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.secondary.opacity(0.3)))
    }
}

struct CardView: View {
    let card: Card

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = card.title {
                Text(RemoteText.title(title)).font(.callout.weight(.semibold))
            }
            if let subtitle = card.subtitle {
                Text(RemoteText.title(subtitle)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(card.sections.enumerated()), id: \.offset) { index, section in
                if index > 0 || card.title != nil || card.subtitle != nil { Divider() }
                VStack(alignment: .leading, spacing: 6) {
                    if let header = section.header {
                        Text(RemoteText.title(header)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(Array(section.widgets.enumerated()), id: \.offset) { _, widget in
                        CardWidgetView(widget: widget)
                    }
                }
            }
        }
        .cardFrame()
    }
}

private struct CardWidgetView: View {
    let widget: CardWidget

    var body: some View {
        switch widget {
        case .text(let text):
            Text(MessageRendering.linkified(text)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .keyValue(let top, let content, let bottom):
            VStack(alignment: .leading, spacing: 1) {
                if let top { Text(RemoteText.title(top)).font(.caption).foregroundStyle(.secondary) }
                if !content.isEmpty { Text(MessageRendering.linkified(content)).textSelection(.enabled) }
                if let bottom { Text(RemoteText.title(bottom)).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .buttons(let buttons):
            FlowLayout(spacing: 8) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                    Button(RemoteText.title(button.text)) {
                        if let url = button.url, url.scheme?.lowercased() == "https" { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.link)
                    .disabled(button.url == nil)
                }
            }
        case .image(let alt):
            Label(alt.map(RemoteText.title) ?? "Image", systemImage: "photo").font(.caption)
                .foregroundStyle(.secondary)
        case .divider:
            Divider()
        }
    }
}

struct OutboxRow: View {
    let item: OutboxItem
    var context: MessageContext?
    var onRepost: (() -> Void)?
    var onDiscard: (() -> Void)?

    /// A message on its way out: my bubble, faded until the server has it, with its status underneath.
    var body: some View {
        HStack {
            Spacer(minLength: 56)
            VStack(alignment: .trailing, spacing: 4) {
                if !item.payload.text.isEmpty {
                    Text(RemoteText.message(item.payload.text))
                        .textSelection(.enabled)
                        .foregroundStyle(Theme.onAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.accent.opacity(isFailure ? 0.45 : 0.6), in: Bubble())
                }
                ForEach(item.payload.attachments) { attachment in
                    Label(
                        RemoteText.title(attachment.filename),
                        systemImage: AttachmentIcon.symbol(
                            name: attachment.filename, contentType: attachment.contentType)
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    statusIcon
                    Text(status).font(.caption).foregroundStyle(isFailure ? Theme.error : .secondary)
                    if isThreadGone, let onRepost {
                        Button("Post as new message", action: onRepost).controlSize(.small)
                    }
                    if isFailure, let onDiscard {
                        Button("Discard", role: .destructive, action: onDiscard).controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: 580, alignment: .trailing)
        }
        .padding(.top, 6)
    }

    private var isFailure: Bool {
        if case .failed = item.state { return true }
        return false
    }

    private var isThreadGone: Bool {
        if case .failed(let reason) = item.state { return reason == "threadGone" }
        return false
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.state {
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.error).font(.caption)
        case .unknown: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange).font(.caption)
        default: ProgressView().controlSize(.mini)
        }
    }

    private var uploading: Bool {
        item.state == .sending && item.payload.attachments.contains { $0.uploadToken == nil }
    }

    private var status: String {
        switch item.state {
        case .queued, .committed: "Sending…"
        case .sending: uploading ? "Uploading…" : "Sending…"
        case .unknown: "Not confirmed yet, retrying"
        case .failed(let reason):
            switch reason {
            case "threadGone": "The thread no longer exists"
            case "fileUnavailable": "Not sent: a file couldn't be read. It may have been moved or deleted."
            case "fileTooLarge": "Not sent: a file is larger than 200 MB."
            case "attachmentsUnsupported": "Not sent: attachments aren't available for this account yet."
            default: "Not sent: \(RemoteText.title(reason))"
            }
        }
    }
}
