import ChatModel
import ChatText
import Foundation
import Testing

/// Checks the parser against real `messages.list` responses kept outside the repository. Set `CHAT_TEXT_CORPUS` to a
/// directory of those JSON files to run it; only counts are reported, never message content.
@Suite struct CorpusTests {
    private static let directory = ProcessInfo.processInfo.environment["CHAT_TEXT_CORPUS"]

    @Test(.enabled(if: directory != nil))
    func everyMessageResolvesAgainstItsPlainText() throws {
        let folder = URL(filePath: try #require(Self.directory), directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var total = 0
        var resolved = 0
        var formatted = 0
        var literal = 0
        for file in files {
            guard let json = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) else { continue }
            let messages =
                (json as? [[String: Any]]) ?? ((json as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
            for message in messages {
                guard let markup = message["formattedText"] as? String else { continue }
                total += 1
                let text = message["text"] as? String ?? ""
                if markup != text { formatted += 1 }
                if ChatMarkup.resolve(markup: markup, text: text, annotations: Self.mentions(message)) != nil {
                    resolved += 1
                } else if markup == text, !ChatMarkup.parse(markup).isPlain {
                    literal += 1
                }
            }
        }
        #expect(total > 0)
        // Google sometimes leaves emphasis markers in `text` and `formattedText` alike; those render plain, exactly.
        #expect(
            resolved + literal == total,
            "\(resolved) of \(total) resolve, \(literal) stay literal, \(formatted) differ from their text")
    }

    private static func mentions(_ message: [String: Any]) -> [Annotation] {
        (message["annotations"] as? [[String: Any]] ?? []).compactMap { annotation in
            guard annotation["type"] as? String == "USER_MENTION",
                let user = ((annotation["userMention"] as? [String: Any])?["user"] as? [String: Any])?["name"]
                    as? String,
                let start = annotation["startIndex"] as? Int, let length = annotation["length"] as? Int
            else { return nil }
            return Annotation(kind: .userMention(UserName(unchecked: user)), startIndex: start, length: length)
        }
    }
}
