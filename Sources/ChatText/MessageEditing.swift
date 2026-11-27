import ChatModel
import Foundation

/// What the composer shows to edit a sent message: its Chat markup with each `<users/…>` token as `@Name`.
public struct EditableText: Hashable, Sendable {
    public var text: String
    public var mentions: [MentionText.Mention]
    /// The message holds something the editor can't reproduce, so saving may change it.
    public var losesFormatting: Bool

    /// The wire text saving this unchanged would send.
    public var original: String { MentionText(visible: text, mentions: mentions).wireText(displayNames: [:]) }

    public init(text: String, mentions: [MentionText.Mention], losesFormatting: Bool) {
        self.text = text
        self.mentions = mentions
        self.losesFormatting = losesFormatting
    }

    /// Loads the markup when every mention token matches the message's mention annotations in order (`@all` may
    /// lack one); otherwise the plain text, flagged when it differs from the markup.
    public init(_ message: Message) {
        guard let markup = message.formattedText, !markup.isEmpty else {
            self.init(text: message.text, mentions: MentionText.mentions(in: message), losesFormatting: false)
            return
        }
        let inventory = ChatMarkup.inventory(markup)
        if let loaded = Self.markup(markup, inventory.mentions, message) {
            self = loaded
            losesFormatting = inventory.hasCustomEmoji || inventory.hasUnknownToken
        } else {
            self.init(text: message.text, mentions: MentionText.mentions(in: message), losesFormatting: true)
        }
    }

    /// Wire text a failed send gave back, with each `<users/…>` token outside code that `names` knows (and `@all`)
    /// shown as `@Name`; unknown tokens stay as they are.
    public init(wire: String, names: [UserName: String]) {
        var text = ""
        var length = 0
        var mentions: [MentionText.Mention] = []
        var cursor = wire.startIndex
        for token in ChatMarkup.inventory(wire).mentions {
            let name = token.user == .all ? "all" : names[token.user]
            guard let name, !name.isEmpty else { continue }
            let display = "@" + name
            let before = wire[cursor..<token.range.lowerBound]
            text += before
            length += before.utf16.count
            mentions.append(.init(range: length..<(length + display.utf16.count), user: token.user, token: display))
            text += display
            length += display.utf16.count
            cursor = token.range.upperBound
        }
        text += wire[cursor...]
        self.init(text: text, mentions: mentions, losesFormatting: false)
    }

    private static func markup(
        _ markup: String, _ tokens: [MarkupInventory.Mention], _ message: Message
    ) -> EditableText? {
        let units = Array(message.text.utf16)
        var annotations = message.annotations.compactMap { annotation -> (UserName, Range<Int>)? in
            guard case .userMention(let user) = annotation.kind else { return nil }
            return (user, annotation.startIndex..<(annotation.startIndex + annotation.length))
        }
        .sorted { $0.1.lowerBound < $1.1.lowerBound }[...]
        var text = ""
        var length = 0
        var mentions: [MentionText.Mention] = []
        var cursor = markup.startIndex
        for token in tokens {
            let display: String
            if let (user, range) = annotations.first, user == token.user {
                guard range.lowerBound >= 0, range.upperBound <= units.count, range.count > 1,
                    units[range.lowerBound] == 0x40
                else { return nil }
                display = String(decoding: Array(units[range]), as: UTF16.self)
                annotations.removeFirst()
            } else if token.user == .all {
                display = "@all"
            } else {
                return nil
            }
            let before = markup[cursor..<token.range.lowerBound]
            text += before
            length += before.utf16.count
            mentions.append(.init(range: length..<(length + display.utf16.count), user: token.user, token: display))
            text += display
            length += display.utf16.count
            cursor = token.range.upperBound
        }
        guard annotations.isEmpty else { return nil }
        text += markup[cursor...]
        return EditableText(text: text, mentions: mentions, losesFormatting: false)
    }
}

/// One edit of a sent message in progress. `basedOn` is nil while the message loads.
public struct PendingEdit: Hashable, Sendable {
    public let attempt: UUID
    public let message: MessageName
    public var basedOn: Timestamp?
    /// The wire text that was loaded; saving the same text sends nothing.
    public var original = ""
    public var losesFormatting = false
    public var saving = false
    public var problem: String?

    public init(attempt: UUID, message: MessageName) {
        self.attempt = attempt
        self.message = message
    }

    /// Takes `copy` as the version being edited and returns what the editor shows.
    public mutating func load(_ copy: Message) -> EditableText {
        let editable = EditableText(copy)
        basedOn = copy.version
        original = editable.original
        losesFormatting = editable.losesFormatting
        return editable
    }

    /// The wire text to save, or nil when nothing changed since the load.
    public func changes(_ wire: String) -> String? { wire == original ? nil : wire }

    /// After a save conflict: the user's text, mentions and the loaded baseline stay, and the next save replaces
    /// `latest`.
    public mutating func conflicted(with latest: Message) {
        saving = false
        basedOn = latest.version
    }
}

extension ChatDocument {
    /// The document with each mention named for display before Google has seen it: `@all`, the cached name, or
    /// `@someone`.
    public func namingMentions(_ names: [UserName: String]) -> ChatDocument {
        func name(_ spans: [Span]) -> [Span] {
            spans.map { span in
                guard case .mention(let user) = span.kind else { return span }
                var named = span
                if user == .all {
                    named.text = "@all"
                } else if let display = names[user], !display.isEmpty {
                    named.text = "@" + display
                } else {
                    named.text = "@someone"
                }
                return named
            }
        }
        return ChatDocument(
            blocks: blocks.map { block in
                switch block {
                case .paragraph(let spans): .paragraph(name(spans))
                case .quote(let spans): .quote(name(spans))
                case .list(let items): .list(items.map { .init(level: $0.level, spans: name($0.spans)) })
                case .code: block
                }
            })
    }
}
