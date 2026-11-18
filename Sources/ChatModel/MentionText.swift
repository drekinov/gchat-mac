import Foundation

/// Outgoing message text with mentions. The composer shows `@Name`; the API needs `<users/{id}>`.
public struct MentionText: Hashable, Sendable {
    public struct Mention: Hashable, Sendable {
        /// UTF-16 range of the visible `@Name` token in `visible`.
        public var range: Range<Int>
        public var user: UserName

        public init(range: Range<Int>, user: UserName) {
            self.range = range
            self.user = user
        }
    }

    public var visible: String
    public var mentions: [Mention]

    public init(visible: String, mentions: [Mention] = []) {
        self.visible = visible
        self.mentions = mentions
    }

    /// The API text: each still-intact mention token becomes `<users/{id}>`, spliced from the end so earlier offsets
    /// stay valid. A token the user edited no longer matches and stays plain text.
    public func wireText(displayNames: [UserName: String]) -> String {
        var units = Array(visible.utf16)
        for mention in mentions.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            guard mention.range.lowerBound >= 0, mention.range.upperBound <= units.count else { continue }
            let token = String(decoding: units[mention.range], as: UTF16.self)
            let expected = "@" + (mention.user == .all ? "all" : displayNames[mention.user] ?? "")
            guard token == expected else { continue }
            units.replaceSubrange(mention.range, with: Array("<\(mention.user.rawValue)>".utf16))
        }
        return String(decoding: units, as: UTF16.self)
    }
}
