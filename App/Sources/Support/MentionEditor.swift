import ChatModel
import ChatSync
import Foundation

/// Mention bookkeeping for the composer: ranges are UTF-16 offsets into the visible text.
struct MentionEditor {
    struct Trigger: Equatable {
        /// UTF-16 offset of the `@`.
        var at: Int
        var prefix: String
    }

    var mentions: [MentionText.Mention] = []

    static let allContact = Contact(
        user: .all, displayName: "all", email: nil, directMessage: nil, source: .chats)

    /// Keeps ranges valid after an edit: later ranges shift, a range the edit touches is dropped.
    mutating func applyEdit(old: String, new: String) {
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
        let oldEnd = before.count - suffix
        let delta = after.count - before.count
        mentions = mentions.compactMap { mention in
            if mention.range.upperBound <= prefix { return mention }
            if mention.range.lowerBound >= oldEnd {
                return MentionText.Mention(
                    range: (mention.range.lowerBound + delta)..<(mention.range.upperBound + delta), user: mention.user)
            }
            return nil
        }
    }

    /// The `@prefix` being typed at `caret` (end of text when nil), if the `@` starts a word outside any mention.
    func trigger(in text: String, caret: Int?) -> Trigger? {
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

    static func filter(_ candidates: [Contact], prefix: String) -> [Contact] {
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return candidates }
        return candidates.filter { contact in
            let name = contact.displayName.lowercased()
            return name.hasPrefix(needle) || name.contains(" " + needle)
        }
    }

    /// Replaces the typed `@prefix` with `@Name ` and records the mention. Returns the new text and caret offset.
    mutating func insert(_ contact: Contact, into text: String, trigger: Trigger) -> (text: String, caret: Int) {
        guard let user = contact.user else { return (text, trigger.at) }
        let token = "@" + (user == .all ? "all" : contact.displayName)
        var units = Array(text.utf16)
        let end = min(trigger.at + 1 + trigger.prefix.utf16.count, units.count)
        units.replaceSubrange(trigger.at..<end, with: Array((token + " ").utf16))
        let updated = String(decoding: units, as: UTF16.self)
        applyEdit(old: text, new: updated)
        mentions.append(MentionText.Mention(range: trigger.at..<(trigger.at + token.utf16.count), user: user))
        return (updated, trigger.at + token.utf16.count + 1)
    }

    func wireText(_ text: String, names: [UserName: String]) -> String {
        MentionText(visible: text, mentions: mentions).wireText(displayNames: names)
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x0A || unit == 0x09
    }
}
