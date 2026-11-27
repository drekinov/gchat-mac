import ChatModel
import Foundation

/// Google's plain `text` for Chat-syntax markup, as the fake derives it: emphasis markers, list and quote prefixes
/// and link targets go; code keeps its backticks and fences; `<users/…>` tokens are left for `applyMentions`.
enum FakeMarkup {
    static let chatSyntax = "MARKUP_SYNTAX_CHAT"

    private static let labelledLink = try! NSRegularExpression(pattern: #"<[A-Za-z][A-Za-z0-9+.-]*:[^\s|>]+\|([^>]+)>"#)
    private static let bareLink = try! NSRegularExpression(pattern: #"<(https?://[^\s|>]+)>"#)
    private static let emphasis = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])([*_~])(?![ \t])(.+?)(?<![ \t])\1(?![\p{L}\p{N}])"#)
    private static let code = try! NSRegularExpression(pattern: "`[^`\n]+`")

    static func plainText(_ markup: String) -> String {
        var lines: [String] = []
        var fenceOpen = false
        for line in markup.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if fenceOpen || line.hasPrefix("```") {
                lines.append(line)
                if fenceOpen {
                    fenceOpen = !line.hasSuffix("```")
                } else {
                    fenceOpen = !(line.count >= 6 && line.hasSuffix("```"))
                }
                continue
            }
            lines.append(inline(dropPrefix(line)))
        }
        return lines.joined(separator: "\n")
    }

    private static func dropPrefix(_ line: String) -> String {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        if indent.isMultiple(of: 4), rest.hasPrefix("* ") || rest.hasPrefix("- ") { return String(rest.dropFirst(2)) }
        if line.hasPrefix("> ") { return String(line.dropFirst(2)) }
        return line
    }

    /// Strips everything outside code spans.
    private static func inline(_ line: String) -> String {
        let ns = line as NSString
        var out = ""
        var cursor = 0
        for match in code.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
            out += strip(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            out += ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        return out + strip(ns.substring(from: cursor))
    }

    private static func strip(_ text: String) -> String {
        var result = replace(labelledLink, in: text, with: "$1")
        result = replace(bareLink, in: result, with: "$1")
        for _ in 0..<3 { result = replace(emphasis, in: result, with: "$2") }
        return result
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }
}

extension State {
    /// The stored text, markup and mention annotations for a body's `text` and `markupSyntax`.
    func compose(_ text: String, syntax: String?) throws(WireError) -> (
        text: String, formattedText: String?, annotations: [Annotation]
    ) {
        switch syntax {
        case nil, "", "MARKUP_SYNTAX_UNSPECIFIED":
            let (plain, mentions) = applyMentions(text)
            return (plain, nil, mentions)
        case FakeMarkup.chatSyntax:
            return compose(markup: text)
        default:
            throw .invalidArgument("Invalid markupSyntax: \(syntax ?? "")")
        }
    }

    func compose(markup: String) -> (text: String, formattedText: String?, annotations: [Annotation]) {
        let (plain, mentions) = applyMentions(FakeMarkup.plainText(markup))
        return (plain, markup, mentions)
    }
}
