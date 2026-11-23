import Foundation

/// Outgoing message text with mentions. The composer shows `@Name`; the API needs `<users/{id}>`.
public struct MentionText: Hashable, Sendable {
    public struct Mention: Hashable, Sendable {
        /// UTF-16 range of the visible `@Name` token in `visible`.
        public var range: Range<Int>
        public var user: UserName
        /// The exact `@Name` text the range must still hold; when nil, it's checked against the current names.
        public var token: String?

        public init(range: Range<Int>, user: UserName, token: String? = nil) {
            self.range = range
            self.user = user
            self.token = token
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
    /// Mentions rebuilt from a sent message's annotations, each keeping the token Google shows.
    public static func mentions(in message: Message) -> [Mention] {
        let units = Array(message.text.utf16)
        return message.annotations.compactMap { annotation in
            guard case .userMention(let user) = annotation.kind else { return nil }
            let range = annotation.startIndex..<(annotation.startIndex + annotation.length)
            guard range.lowerBound >= 0, range.upperBound <= units.count else { return nil }
            let token = String(decoding: units[range], as: UTF16.self)
            guard token.hasPrefix("@") else { return nil }
            return Mention(range: range, user: user, token: token)
        }
    }

    public func wireText(displayNames: [UserName: String]) -> String {
        var units = Array(visible.utf16)
        for mention in mentions.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            guard mention.range.lowerBound >= 0, mention.range.upperBound <= units.count else { continue }
            let token = String(decoding: units[mention.range], as: UTF16.self)
            let expected = mention.token ?? "@" + (mention.user == .all ? "all" : displayNames[mention.user] ?? "")
            guard token == expected else { continue }
            units.replaceSubrange(mention.range, with: Array("<\(mention.user.rawValue)>".utf16))
        }
        return String(decoding: units, as: UTF16.self)
    }
}
