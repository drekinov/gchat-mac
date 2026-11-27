import AppKit
import ChatModel
import ChatText
import SwiftUI

/// The resolved markup of a message, or nil when its plain text renders it the same or more faithfully.
@MainActor
enum MessageMarkup {
    private struct Key: Hashable {
        let markup: String
        let text: String
        let annotations: [Annotation]
    }

    private static let capacity = 500
    private static var cache: [Key: (document: ChatDocument?, used: UInt64)] = [:]
    private static var clock: UInt64 = 0

    static func document(for message: Message) -> ChatDocument? {
        guard let markup = message.formattedText, !markup.isEmpty, !message.text.isEmpty else { return nil }
        let key = Key(markup: markup, text: message.text, annotations: message.annotations)
        clock += 1
        if let hit = cache[key] {
            cache[key]?.used = clock
            return hit.document
        }
        let document = resolve(key)
        if cache.count >= capacity { evictOldest() }
        cache[key] = (document, clock)
        return document
    }

    private static func resolve(_ key: Key) -> ChatDocument? {
        // Cleaning or truncation would shift the annotation offsets the markup is matched against.
        guard RemoteText.message(key.markup) == key.markup, RemoteText.message(key.text) == key.text,
            let document = ChatMarkup.resolve(markup: key.markup, text: key.text, annotations: key.annotations),
            !document.isPlain
        else { return nil }
        return document
    }

    private static func evictOldest() {
        let keep = capacity * 4 / 5
        let cutoff = cache.values.map(\.used).sorted(by: >)[keep - 1]
        cache = cache.filter { $0.value.used >= cutoff }
    }
}

/// A message's formatted blocks inside its bubble.
struct FormattedMessageText: View {
    let document: ChatDocument
    let me: UserName?
    /// On an accent bubble, where links, mentions and code switch to white tints.
    let onAccent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ChatDocument.Block) -> some View {
        switch block {
        case .paragraph(let spans):
            if let text = runs(spans) {
                Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        case .quote(let spans):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(onAccent ? Color.white.opacity(0.6) : Color(nsColor: .tertiaryLabelColor))
                    .frame(width: 3)
                Text(runs(spans) ?? "").textSelection(.enabled)
                    .foregroundStyle(onAccent ? Color.white.opacity(0.85) : Color(nsColor: .secondaryLabelColor))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(Self.bullets[item.level % Self.bullets.count])
                        Text(runs(item.spans) ?? "").textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(min(item.level, 6)) * 16)
                }
            }
        case .code(let code, _):
            CodeBlock(code: code, onAccent: onAccent)
        }
    }

    private static let bullets = ["•", "◦", "▪︎"]

    /// The spans as one attributed run, without the blank lines a block's edges carry in the markup; nil when empty.
    private func runs(_ spans: [Span]) -> AttributedString? {
        var result = AttributedString()
        for span in spans { result += run(span) }
        let characters = result.characters
        guard let first = characters.firstIndex(where: { $0 != "\n" }),
            let last = characters.lastIndex(where: { $0 != "\n" })
        else { return nil }
        return AttributedString(result[first...last])
    }

    private func run(_ span: Span) -> AttributedString {
        var run = AttributedString(span.text)
        let all = run.startIndex..<run.endIndex
        let bold = span.style.contains(.bold)
        let italic = span.style.contains(.italic)
        if span.style.contains(.code) {
            run[all].font = .system(size: 12, design: .monospaced).weight(bold ? .bold : .regular)
            run[all].backgroundColor = onAccent ? Color.white.opacity(0.2) : Theme.inlineCode
        } else if bold || italic {
            var font = Font.body
            if bold { font = font.bold() }
            if italic { font = font.italic() }
            run[all].font = font
        }
        if span.style.contains(.strikethrough) { run[all].strikethroughStyle = .single }
        switch span.kind {
        case .text:
            if !span.style.contains(.code) { MessageRendering.linkify(span.text, underlined: onAccent, in: &run) }
        case .link(let target):
            if let url = URL(string: target), url.scheme?.lowercased() == "https", url.host() != nil {
                run[all].link = url
                if onAccent { run[all].underlineStyle = .single }
            }
        case .mention(let user):
            run[all].font = .body.weight(.semibold)
            run[all].foregroundColor = onAccent ? Theme.onAccent : Theme.accentText
            if user == me || user == .all {
                run[all].backgroundColor = onAccent ? Color.white.opacity(0.22) : Theme.selection
            }
        case .customEmoji:
            run[all].font = .body.monospaced()
            if !onAccent {
                run[all].foregroundColor = Color(red: 0.50, green: 0.30, blue: 0.80)
                run[all].backgroundColor = Color(red: 0.50, green: 0.30, blue: 0.80).opacity(0.12)
            }
        }
        return run
    }
}

/// A fenced code block: monospaced, scrolling sideways instead of wrapping, with Copy on hover.
private struct CodeBlock: View {
    let code: String
    let onAccent: Bool
    @State private var hovering = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content
            ScrollView(.horizontal, showsIndicators: false) { content }
        }
        .background(
            onAccent ? Color.black.opacity(0.22) : Theme.insetSurface,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(6)
                .help("Copy the code")
            }
        }
        .onHover { hovering = $0 }
    }

    private var content: some View {
        Text(code)
            .font(.system(size: 12, design: .monospaced))
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }
}
