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

    static func attributed(_ message: Message, me: UserName?) -> AttributedString {
        let raw = message.text
        let clean = RemoteText.message(raw)
        var result = AttributedString(clean)
        if clean == raw { styleAnnotations(of: message, raw: raw, me: me, in: &result) }
        linkify(clean, in: &result)
        return result
    }

    static func linkified(_ raw: String) -> AttributedString {
        let clean = RemoteText.message(raw)
        var result = AttributedString(clean)
        linkify(clean, in: &result)
        return result
    }

    private static func styleAnnotations(
        of message: Message, raw: String, me: UserName?, in result: inout AttributedString
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
                result[from..<to].foregroundColor = .accentColor
                if user == me || user == .all { result[from..<to].backgroundColor = Color.accentColor.opacity(0.16) }
            case .customEmoji:
                result[from..<to].font = .body.monospaced()
                result[from..<to].foregroundColor = Color(red: 0.50, green: 0.30, blue: 0.80)
                result[from..<to].backgroundColor = Color(red: 0.50, green: 0.30, blue: 0.80).opacity(0.12)
            case .slashCommand, .richLink:
                continue
            }
        }
    }

    private static func linkify(_ text: String, in result: inout AttributedString) {
        guard let detector = linkDetector, text.utf8.count < 20_000 else { return }
        let whole = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: whole) {
            guard let url = match.url, url.scheme?.lowercased() == "https", url.host() != nil,
                let range = Range(match.range, in: text),
                let from = AttributedString.Index(range.lowerBound, within: result),
                let to = AttributedString.Index(range.upperBound, within: result)
            else { continue }
            result[from..<to].link = url
        }
    }
}

struct MessageRowModel: Identifiable {
    let message: Message
    let showsHeader: Bool
    let replies: Int

    var id: MessageName { message.id }

    static func build(_ messages: [Message], threaded: Bool, showsReplies: Bool) -> [MessageRowModel] {
        var counts: [ThreadName: Int] = [:]
        if showsReplies {
            for message in messages where message.isThreadReply && !message.isDeleted {
                if let thread = message.thread { counts[thread, default: 0] += 1 }
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
            rows.append(MessageRowModel(message: message, showsHeader: header, replies: replies))
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

struct MessageRow: View {
    let row: MessageRowModel
    let context: MessageContext
    var onOpenThread: ((ThreadName) -> Void)?
    @State private var hovering = false
    @State private var pickerOpen = false
    @Environment(\.forcedHoverMessage) private var forcedHover

    var body: some View {
        let message = row.message
        let showsBar = !message.isDeleted && (hovering || pickerOpen || forcedHover == message.name)
        HStack(alignment: .top, spacing: 10) {
            if row.showsHeader {
                PhotoAvatar(
                    name: senderName, url: context.photoURL(message.sender.name), media: context.media, size: 32)
            } else {
                Color.clear.frame(width: 32, height: 1)
            }
            VStack(alignment: .leading, spacing: 4) {
                if row.showsHeader {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(senderName).font(.body.weight(.semibold))
                        if message.sender.type == .bot {
                            Text("BOT").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4)
                                .background(Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                        }
                        Text(TimeFormat.message(message.createTime)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if message.isDeleted {
                    Text("Message deleted").italic().foregroundStyle(.secondary)
                } else {
                    liveContent(message)
                }
                if row.replies > 0, let thread = message.thread, let onOpenThread {
                    Button("\(row.replies) \(row.replies == 1 ? "reply" : "replies")") { onOpenThread(thread) }
                        .buttonStyle(.link)
                        .font(.callout.weight(.medium))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, row.showsHeader ? 8 : 0)
        .background(showsBar ? Color.primary.opacity(0.04) : .clear)
        .overlay(alignment: .topTrailing) {
            if showsBar { actionBar(message).padding(.trailing, 8).padding(.top, row.showsHeader ? 10 : 0) }
        }
        .onHover { hovering = $0 }
    }

    private func actionBar(_ message: Message) -> some View {
        let enabled = context.actions?.canReact ?? false
        return HStack(spacing: 2) {
            Button {
                pickerOpen = true
            } label: {
                Image(systemName: "face.smiling").frame(width: 24, height: 22)
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
            if let thread = message.thread, let onOpenThread {
                Button {
                    onOpenThread(thread)
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right").frame(width: 24, height: 22)
                }
                .help("Reply in thread")
            }
        }
        .buttonStyle(.borderless)
        .padding(2)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.3)))
    }

    @ViewBuilder
    private func liveContent(_ message: Message) -> some View {
        if let quoted = message.quoted {
            let resolved = context.quote(quoted)
            QuotedBlock(sender: resolved.sender, text: resolved.text)
        }
        if !message.text.isEmpty {
            Text(MessageRendering.attributed(message, me: context.me)).textSelection(.enabled)
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
        if !message.reactions.isEmpty {
            ReactionPills(reactions: message.reactions, message: message.name, actions: context.actions).padding(
                .top, 2)
        }
    }

    private var senderName: String {
        let name = row.message.sender.displayName.map(RemoteText.title) ?? ""
        return name.isEmpty ? "Unknown" : name
    }
}

struct QuotedBlock: View {
    let sender: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.5)).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(sender).font(.caption.weight(.semibold))
                Text(text.isEmpty ? "Original message unavailable" : text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
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
        padding(10)
            .frame(maxWidth: 420, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PhotoAvatar(
                name: context?.me.flatMap { context?.names[$0] } ?? "You",
                url: context?.me.flatMap { context?.photoURL($0) }, media: context?.media, size: 32
            )
            .opacity(0.5)
            VStack(alignment: .leading, spacing: 3) {
                if !item.payload.text.isEmpty {
                    Text(RemoteText.message(item.payload.text)).foregroundStyle(.secondary).textSelection(.enabled)
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
                    Text(status).font(.caption).foregroundStyle(isFailure ? Color.red : .secondary)
                    if isThreadGone, let onRepost {
                        Button("Post as new message", action: onRepost).controlSize(.small)
                    }
                    if isFailure, let onDiscard {
                        Button("Discard", role: .destructive, action: onDiscard).controlSize(.small)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
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
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).font(.caption)
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
