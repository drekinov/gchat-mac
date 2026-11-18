import ChatModel
import Foundation

struct Clause {
    var key: String
    var op: Character
    var value: String

    static func parse(_ text: String) -> Clause? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let index = trimmed.firstIndex(where: { ">< =:".contains($0) }) else { return nil }
        let key = trimmed[..<index].trimmingCharacters(in: .whitespaces)
        var rest = trimmed[trimmed.index(after: index)...].trimmingCharacters(in: .whitespaces)
        var op = trimmed[index]
        if op == " " {
            guard let next = rest.first, "<>=:".contains(next) else { return nil }
            op = next
            rest = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        guard !key.isEmpty, !rest.isEmpty else { return nil }
        return Clause(key: key, op: op, value: rest)
    }

    var unquoted: String? {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
        return String(value.dropFirst().dropLast())
    }

    var timestamp: Timestamp? {
        unquoted.flatMap { Timestamp(rfc3339: $0) }
    }
}

struct MessageFilter {
    var after: Timestamp?
    var before: Timestamp?
    var thread: ThreadName?

    static func parse(_ text: String?) throws(WireError) -> MessageFilter {
        var filter = MessageFilter()
        guard let text, !text.isEmpty else { return filter }
        for part in text.components(separatedBy: " AND ") {
            guard let clause = Clause.parse(part) else { throw .invalidArgument("Invalid filter: \(part)") }
            switch (clause.key, clause.op) {
            case ("createTime", ">"), ("createTime", "<"):
                guard let time = clause.timestamp else { throw .invalidArgument("Invalid createTime: \(part)") }
                if clause.op == ">" { filter.after = time } else { filter.before = time }
            case ("thread.name", "="):
                guard let thread = ThreadName(clause.unquoted ?? clause.value) else {
                    throw .invalidArgument("Invalid thread name: \(part)")
                }
                filter.thread = thread
            default:
                throw .invalidArgument("Unsupported filter clause: \(part)")
            }
        }
        return filter
    }

    func matches(_ message: Message) -> Bool {
        (after.map { message.createTime > $0 } ?? true) && (before.map { message.createTime < $0 } ?? true)
            && (thread.map { message.thread == $0 } ?? true)
    }
}

/// `startTime` is exclusive and `endTime` inclusive. Without `startTime` the window opens 28 days before `now`,
/// which is also the furthest back a `startTime` may reach.
struct EventFilter {
    static let maxWindow = Duration.seconds(28 * 24 * 3600)

    var start: Timestamp
    var end: Timestamp?
    var types: [String] = []

    static func parse(_ text: String?, now: Timestamp) throws(WireError) -> EventFilter {
        guard let text, !text.isEmpty else { throw .invalidArgument("filter with eventTypes is required") }
        let earliest = now.adding(.zero - maxWindow)
        var filter = EventFilter(start: earliest)
        var explicitStart: Timestamp?
        for part in text.components(separatedBy: " AND ") {
            var group = part.trimmingCharacters(in: .whitespaces)
            if group.hasPrefix("(") && group.hasSuffix(")") { group = String(group.dropFirst().dropLast()) }
            for alternative in group.components(separatedBy: " OR ") {
                guard let clause = Clause.parse(alternative) else { throw .invalidArgument("Invalid filter: \(part)") }
                switch (clause.key, clause.op) {
                case ("startTime", "="), ("endTime", "="):
                    guard let time = clause.timestamp else { throw .invalidArgument("Invalid time: \(part)") }
                    if clause.key == "startTime" { explicitStart = time } else { filter.end = time }
                case ("eventTypes", ":"):
                    guard let type = clause.unquoted, type.hasPrefix("google.workspace.chat.") else {
                        throw .invalidArgument("Invalid event type: \(part)")
                    }
                    filter.types.append(type)
                default:
                    throw .invalidArgument("Unsupported filter clause: \(part)")
                }
            }
        }
        guard !filter.types.isEmpty else { throw .invalidArgument("eventTypes is required") }
        if let explicitStart {
            guard explicitStart >= earliest else { throw .invalidArgument("startTime is more than 28 days old") }
            filter.start = explicitStart
            if let end = filter.end, explicitStart.adding(maxWindow) < end {
                throw .invalidArgument("endTime - startTime must not exceed 28 days")
            }
        }
        return filter
    }

    func matches(_ event: StoredEvent) -> Bool {
        guard event.time > start, end.map({ event.time <= $0 }) ?? true else { return false }
        return types.contains(event.payload.eventType)
    }
}

struct PageRequest {
    var size: Int
    var offset: Int
    var signature: String

    static func parse(
        _ incoming: IncomingRequest, account: UserName, defaultSize: Int = 100, maxSize: Int = 1000
    ) throws(WireError) -> PageRequest {
        var size = defaultSize
        if let text = incoming.value("pageSize"), !text.isEmpty {
            guard let value = Int(text) else { throw .invalidArgument("Invalid pageSize") }
            size = min(max(value, 1), maxSize)
        }
        let canonical = incoming.query.filter { $0.name != "pageToken" }
            .map { "\($0.name)=\($0.value ?? "")" }.sorted().joined(separator: "&")
        let signature = hash("\(account.rawValue)|\(incoming.path)|\(canonical)")
        var offset = 0
        if let token = incoming.value("pageToken"), !token.isEmpty {
            guard let data = Data(base64Encoded: token), let text = String(data: data, encoding: .utf8),
                let separator = text.firstIndex(of: ":"), let value = Int(text[..<separator]), value >= 0
            else { throw .invalidArgument("Invalid pageToken") }
            guard text[text.index(after: separator)...] == signature else {
                throw .invalidArgument("pageToken does not match the request parameters")
            }
            offset = value
        }
        return PageRequest(size: size, offset: offset, signature: signature)
    }

    func slice<T>(_ items: [T]) -> (page: [T], next: String?) {
        let start = min(offset, items.count)
        let end = min(items.count, start + size)
        let next = end < items.count ? Data("\(end):\(signature)".utf8).base64EncodedString() : nil
        return (Array(items[start..<end]), next)
    }

    private static func hash(_ text: String) -> String {
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return String(value, radix: 16)
    }
}

/// `user.name`, `emoji.unicode` and `emoji.custom_emoji.uid` comparisons joined with AND, OR and parentheses.
/// AND binds tighter than OR.
indirect enum ReactionFilter {
    case user(String)
    case unicode(String)
    case customUID(String)
    case and(ReactionFilter, ReactionFilter)
    case or(ReactionFilter, ReactionFilter)

    private enum Token: Equatable {
        case open, close, equals, and, or
        case word(String)
        case quoted(String)
    }

    static func parse(_ text: String?) throws(WireError) -> ReactionFilter? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var parser = Parser(tokens: try tokenize(text), text: text)
        let filter = try parser.expression()
        guard parser.position == parser.tokens.count else { throw .invalidArgument("Invalid filter: \(text)") }
        return filter
    }

    private static func tokenize(_ text: String) throws(WireError) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                index = text.index(after: index)
            } else if character == "(" || character == ")" || character == "=" {
                tokens.append(character == "(" ? .open : character == ")" ? .close : .equals)
                index = text.index(after: index)
            } else if character == "\"" {
                guard let end = text[text.index(after: index)...].firstIndex(of: "\"") else {
                    throw .invalidArgument("Unterminated string in filter: \(text)")
                }
                tokens.append(.quoted(String(text[text.index(after: index)..<end])))
                index = text.index(after: end)
            } else {
                var end = index
                while end < text.endIndex, !text[end].isWhitespace, !"()=\"".contains(text[end]) {
                    end = text.index(after: end)
                }
                let word = String(text[index..<end])
                tokens.append(word == "AND" ? .and : word == "OR" ? .or : .word(word))
                index = end
            }
        }
        return tokens
    }

    private struct Parser {
        var tokens: [Token]
        var text: String
        var position = 0

        init(tokens: [Token], text: String) {
            self.tokens = tokens
            self.text = text
        }

        mutating func accept(_ token: Token) -> Bool {
            guard position < tokens.count, tokens[position] == token else { return false }
            position += 1
            return true
        }

        mutating func expression() throws(WireError) -> ReactionFilter {
            var left = try conjunction()
            while accept(.or) { left = .or(left, try conjunction()) }
            return left
        }

        mutating func conjunction() throws(WireError) -> ReactionFilter {
            var left = try atom()
            while accept(.and) { left = .and(left, try atom()) }
            return left
        }

        mutating func atom() throws(WireError) -> ReactionFilter {
            if accept(.open) {
                let inner = try expression()
                guard accept(.close) else { throw .invalidArgument("Unbalanced parentheses in filter: \(text)") }
                return inner
            }
            guard position + 2 < tokens.count, case .word(let field) = tokens[position],
                tokens[position + 1] == .equals,
                case .quoted(let value) = tokens[position + 2]
            else { throw .invalidArgument("Invalid filter: \(text)") }
            position += 3
            switch field {
            case "user.name": return .user(value)
            case "emoji.unicode": return .unicode(value)
            case "emoji.custom_emoji.uid": return .customUID(value)
            default: throw .invalidArgument("Unsupported filter field: \(field)")
            }
        }
    }

    func matches(_ reaction: ReactionRecord, uid: (CustomEmojiName) -> String) -> Bool {
        switch self {
        case .user(let name): reaction.user.name.rawValue == name
        case .unicode(let text): reaction.emoji == .unicode(text)
        case .customUID(let value):
            if case .custom(let name, _) = reaction.emoji { uid(name) == value } else { false }
        case .and(let left, let right): left.matches(reaction, uid: uid) && right.matches(reaction, uid: uid)
        case .or(let left, let right): left.matches(reaction, uid: uid) || right.matches(reaction, uid: uid)
        }
    }
}
