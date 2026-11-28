import ChatModel

/// Mention bookkeeping for the composer: ranges are UTF-16 offsets into the visible text.
public struct MentionEditor: Sendable {
    public struct Trigger: Equatable, Sendable {
        /// UTF-16 offset of the `@`.
        public var at: Int
        public var prefix: String

        public init(at: Int, prefix: String) {
            self.at = at
            self.prefix = prefix
        }
    }

    public var mentions: [MentionText.Mention]

    /// Recent texts that held mentions, by hash, so undo and redo can bring their mentions back.
    private var remembered: [(hash: Int, mentions: [MentionText.Mention])] = []
    private static let rememberLimit = 128

    public init(mentions: [MentionText.Mention] = []) { self.mentions = mentions }

    public var ranges: [Range<Int>] { mentions.map(\.range) }

    /// Keeps ranges valid after an edit: later ranges shift, a range the edit touches is dropped.
    public mutating func applyEdit(old: String, new: String) {
        guard !mentions.isEmpty else { return }
        let before = Array(old.utf16)
        let after = Array(new.utf16)
        let shortest = min(before.count, after.count)
        var prefix = 0
        while prefix < shortest, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix, before[before.count - 1 - suffix] == after[after.count - 1 - suffix] {
            suffix += 1
        }
        let edit = TextEdit(
            range: prefix..<(before.count - suffix),
            replacement: String(decoding: after[prefix..<(after.count - suffix)], as: UTF16.self))
        apply([edit])
    }

    /// Shifts ranges for explicit edits; a mention an edit cuts into is dropped, one it only borders is kept.
    public mutating func apply(_ edits: [TextEdit]) {
        guard !mentions.isEmpty, !edits.isEmpty else { return }
        let kept = mentions.compactMap { mention -> MentionText.Mention? in
            let range = mention.range
            let cuts = edits.contains { edit in
                edit.range.isEmpty
                    ? range.lowerBound < edit.range.lowerBound && edit.range.lowerBound < range.upperBound
                    : edit.range.lowerBound < range.upperBound && range.lowerBound < edit.range.upperBound
            }
            guard !cuts else { return nil }
            let lower = TextEdit.map(range.lowerBound, through: edits, after: true)
            return MentionText.Mention(
                range: lower..<(lower + range.count), user: mention.user, token: mention.token)
        }
        mentions = kept
    }

    /// Records the mentions `text` holds, for `recall` after undo or redo returns to it.
    public mutating func remember(_ text: String) {
        guard !mentions.isEmpty || !remembered.isEmpty else { return }
        let hash = text.hashValue
        remembered.removeAll { $0.hash == hash }
        guard !mentions.isEmpty else { return }
        remembered.append((hash, mentions))
        if remembered.count > Self.rememberLimit { remembered.removeFirst(remembered.count - Self.rememberLimit) }
    }

    /// Takes the mentions remembered for `text`, keeping those whose token still reads the same. False when the
    /// text wasn't seen with mentions.
    public mutating func recall(_ text: String) -> Bool {
        let hash = text.hashValue
        guard let entry = remembered.last(where: { $0.hash == hash }) else { return false }
        let units = Array(text.utf16)
        mentions = entry.mentions.filter { mention in
            guard mention.range.upperBound <= units.count else { return false }
            guard let token = mention.token else { return true }
            return String(decoding: units[mention.range], as: UTF16.self) == token
        }
        return true
    }

    /// The `@prefix` being typed at `caret` (end of text when nil), if the `@` starts a word outside any mention.
    public func trigger(in text: String, caret: Int?) -> Trigger? {
        let units = Array(text.utf16)
        let end = min(caret ?? units.count, units.count)
        var index = end - 1
        var spaces = 0
        while index >= 0, end - index <= 40 {
            let unit = units[index]
            if unit == 0x40 {
                let startsWord = index == 0 || Self.isWhitespace(units[index - 1])
                let insideMention = mentions.contains { $0.range.contains(index) }
                guard startsWord, !insideMention else { return nil }
                return Trigger(at: index, prefix: String(decoding: units[(index + 1)..<end], as: UTF16.self))
            }
            if unit == 0x0A { return nil }
            if unit == 0x20 {
                spaces += 1
                if spaces > 2 { return nil }
            }
            index -= 1
        }
        return nil
    }

    /// The edit that replaces the typed `@prefix` with `token` and a space, and the caret after it.
    public func insertion(of token: String, in text: String, trigger: Trigger) -> (edit: TextEdit, caret: Int) {
        let count = text.utf16.count
        let start = min(trigger.at, count)
        let end = min(trigger.at + 1 + trigger.prefix.utf16.count, count)
        let edit = TextEdit(range: start..<end, replacement: token + " ")
        return (edit, start + token.utf16.count + 1)
    }

    /// Records the mention `insertion` made: shifts the others and adds it.
    public mutating func recordInsertion(_ edit: TextEdit, user: UserName, token: String) {
        apply([edit])
        mentions.append(
            MentionText.Mention(
                range: edit.range.lowerBound..<(edit.range.lowerBound + token.utf16.count), user: user, token: token))
    }

    /// Replaces the typed `@prefix` with `token` and records the mention. Returns the new text and caret offset.
    public mutating func insert(_ user: UserName, token: String, into text: String, trigger: Trigger) -> (
        text: String, caret: Int
    ) {
        let (edit, caret) = insertion(of: token, in: text, trigger: trigger)
        recordInsertion(edit, user: user, token: token)
        return (TextEdit.apply([edit], to: text), caret)
    }

    public func wireText(_ text: String, names: [UserName: String]) -> String {
        MentionText(visible: text, mentions: mentions).wireText(displayNames: names)
    }

    public static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09
    }
}
