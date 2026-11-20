import ChatModel
import ChatSync
import SwiftUI
import UniformTypeIdentifiers

/// Wraps its children onto new rows when the proposed width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, result.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width, width.isFinite {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), frames)
    }
}

enum AttachmentIcon {
    static func symbol(for attachment: Attachment) -> String {
        symbol(name: attachment.contentName, contentType: attachment.contentType)
    }

    static func symbol(name: String, contentType: String) -> String {
        let type = contentType.lowercased()
        if type.contains("google-apps.document") || type.contains("wordprocessingml") { return "doc.text" }
        if type.contains("google-apps.spreadsheet") || type.contains("spreadsheetml") { return "tablecells" }
        if type.contains("google-apps.presentation") || type.contains("presentationml") {
            return "rectangle.on.rectangle.angled"
        }
        if type == "image/gif" { return "photo.on.rectangle" }
        let resolved = UTType(mimeType: type) ?? UTType(filenameExtension: (name as NSString).pathExtension)
        guard let resolved else { return "doc" }
        if resolved.conforms(to: .image) { return "photo" }
        if resolved.conforms(to: .movie) || resolved.conforms(to: .video) { return "film" }
        if resolved.conforms(to: .audio) { return "waveform" }
        if resolved.conforms(to: .pdf) { return "doc.richtext" }
        if resolved.conforms(to: .archive) { return "doc.zipper" }
        if resolved.conforms(to: .spreadsheet) { return "tablecells" }
        if resolved.conforms(to: .presentation) { return "rectangle.on.rectangle.angled" }
        return "doc"
    }

    /// A readable type name; unknown types fall back to the sanitized MIME string.
    static func typeLabel(for attachment: Attachment) -> String {
        typeLabel(contentType: attachment.contentType)
    }

    static func typeLabel(contentType: String) -> String {
        let type = contentType.lowercased()
        let known: [(String, String)] = [
            ("google-apps.document", "Google Doc"), ("google-apps.spreadsheet", "Google Sheet"),
            ("google-apps.presentation", "Google Slides"), ("wordprocessingml", "Word document"),
            ("spreadsheetml", "Excel spreadsheet"), ("presentationml", "PowerPoint presentation"),
        ]
        if let match = known.first(where: { type.contains($0.0) }) { return match.1 }
        if let description = UTType(mimeType: type)?.localizedDescription, let first = description.first {
            return first.uppercased() + description.dropFirst()
        }
        return RemoteText.title(contentType)
    }

    static func isImage(_ attachment: Attachment) -> Bool {
        if case .drive = attachment.source { return false }
        return attachment.contentType.lowercased().hasPrefix("image/")
    }
}

struct AttachmentView: View {
    let attachment: Attachment
    var media: MediaLoader?
    var onPreview: (Attachment) -> Void = { _ in }
    @AppStorage("inlineImagePreviews") private var inlinePreviews = false

    var body: some View {
        if inlinePreviews, AttachmentIcon.isImage(attachment) {
            if let media {
                InlineImageView(attachment: attachment, media: media) { onPreview(attachment) }
            } else {
                ImagePlaceholderCard(attachment: attachment)
            }
        } else {
            AttachmentChip(attachment: attachment, media: media, onPreview: onPreview)
        }
    }
}

struct GifAttachmentView: View {
    let url: URL
    let media: MediaLoader
    var onPreview: (URL) -> Void = { _ in }
    @AppStorage("inlineImagePreviews") private var inlinePreviews = false

    var body: some View {
        if inlinePreviews {
            AnimatedGifView(url: url, media: media)
        } else {
            Button {
                onPreview(url)
            } label: {
                FileChipLabel(
                    symbol: "photo.on.rectangle", name: "GIF",
                    detail: url.host().map(RemoteText.title) ?? "Animated image")
            }
            .buttonStyle(.plain)
            .help("Preview GIF")
            .accessibilityLabel("Animated image")
            .accessibilityHint("Opens a preview")
        }
    }
}

extension View {
    /// One fixed height for every chip, so a row never changes size.
    /// Files sit in a bubble of their own, in the colour of other people's bubbles.
    fileprivate func fileChipFrame() -> some View {
        padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(maxWidth: 340, minHeight: 50, maxHeight: 50, alignment: .leading)
            .background(Theme.incomingBubble, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    /// A file's symbol on a small tile inside its bubble.
    fileprivate func fileIconTile() -> some View {
        font(.system(size: 15))
            .foregroundStyle(Theme.accentText)
            .frame(width: 34, height: 34)
            .background(Theme.insetSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct FileChipLabel: View {
    let symbol: String
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).fileIconTile()
            VStack(alignment: .leading, spacing: 0) {
                Text(name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .fileChipFrame()
    }
}

struct AttachmentChip: View {
    let attachment: Attachment
    var media: MediaLoader?
    var onPreview: ((Attachment) -> Void)?

    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: AttachmentIcon.symbol(for: attachment)).fileIconTile()
            VStack(alignment: .leading, spacing: 0) {
                Text(RemoteText.title(attachment.contentName)).font(.callout.weight(.medium)).lineLimit(1)
                    .truncationMode(.middle)
                Text(failure ?? AttachmentIcon.typeLabel(for: attachment)).font(.caption)
                    .foregroundStyle(failure == nil ? Color.secondary : Theme.error)
                    .lineLimit(1)
            }
            if busy { ProgressView().controlSize(.small) }
            if case .drive(let fileID) = attachment.source {
                Button("Open in Drive") { AttachmentActions.openInDrive(fileID) }
                    .disabled(AttachmentActions.driveURL(fileID) == nil)
                    .controlSize(.small)
            }
        }
        .fileChipFrame()
        .onTapGesture { open() }
        .contextMenu { menu }
        .help(canOpen ? "Open \(RemoteText.title(attachment.contentName))" : RemoteText.title(attachment.contentName))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(canOpen ? .isButton : [])
    }

    private var canOpen: Bool {
        if case .uploaded = attachment.source { return media != nil }
        return false
    }

    private var previews: Bool { canOpen && AttachmentIcon.isImage(attachment) && onPreview != nil }

    @ViewBuilder
    private var menu: some View {
        switch attachment.source {
        case .uploaded:
            if media != nil {
                if previews { Button("Preview") { open() } }
                Button("Open") { openExternally() }
                Button("Save As…") { saveAs() }
            }
        case .drive(let fileID):
            Button("Open in Drive") { AttachmentActions.openInDrive(fileID) }
            Button("Copy link") { AttachmentActions.copyDriveLink(fileID) }
        }
    }

    private func open() {
        if previews {
            onPreview?(attachment)
        } else {
            openExternally()
        }
    }

    private func openExternally() {
        guard canOpen, let media, !busy else { return }
        busy = true
        failure = nil
        Task {
            failure = await AttachmentActions.open(attachment, media: media)
            busy = false
        }
    }

    private func saveAs() {
        guard let media else { return }
        Task { failure = await AttachmentActions.saveAs(attachment, media: media) }
    }
}

struct ImagePlaceholderCard: View {
    let attachment: Attachment

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: AttachmentIcon.symbol(for: attachment)).font(.system(size: 26)).foregroundStyle(
                .secondary)
            Text("Image preview arrives with media support").font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(RemoteText.title(attachment.contentName)).font(.caption.weight(.medium)).lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(10)
        .frame(width: 220, height: 110)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }
}

struct ReactionPills: View {
    let reactions: [ReactionSummary]
    let message: MessageName
    var actions: ReactionActions?

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(reactions.enumerated()), id: \.offset) { _, reaction in
                pill(reaction)
            }
        }
    }

    private func pill(_ reaction: ReactionSummary) -> some View {
        let mine = actions?.isMine(reaction.emoji, message) ?? false
        let enabled = actions?.canReact ?? false
        return Button {
            actions?.toggle(reaction.emoji, message)
        } label: {
            HStack(spacing: 4) {
                emoji(reaction.emoji)
                Text("\(reaction.count)").font(.caption.monospacedDigit())
                    .foregroundStyle(mine ? Color.accentColor : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(mine ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    mine ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: mine ? 1.2 : 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(tooltip(reaction, mine: mine))
        .accessibilityLabel(
            "\(reaction.count) \(reaction.count == 1 ? "reaction" : "reactions")\(mine ? ", including yours" : "")"
        )
        .accessibilityAddTraits(mine ? .isSelected : [])
    }

    private func tooltip(_ reaction: ReactionSummary, mine: Bool) -> String {
        let count = "\(reaction.count) \(reaction.count == 1 ? "reaction" : "reactions")"
        return mine ? "\(count). You reacted; click to remove." : count
    }

    @ViewBuilder
    private func emoji(_ emoji: Emoji) -> some View {
        switch emoji {
        case .unicode(let text):
            Text(RemoteText.title(text))
        case .custom(_, let shortcode):
            Text(":\(EmojiPick.bareShortcode(shortcode ?? "emoji")):")
                .font(.caption.monospaced())
                .foregroundStyle(Color(red: 0.50, green: 0.30, blue: 0.80))
        }
    }
}
