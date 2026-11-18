import ChatModel
import Foundation

extension Wire {
    /// One shape for legacy `cards` and `cardsV2[].card`; each field exists in only one of the two.
    struct CardDTO: Decodable, Sendable {
        struct Header: Decodable, Sendable {
            var title: String?
            var subtitle: String?
        }
        var header: Lossy<Header>?
        var sections: [Lossy<CardSectionDTO>]?
    }

    struct CardV2DTO: Decodable, Sendable {
        var card: Lossy<CardDTO>?
    }

    struct CardSectionDTO: Decodable, Sendable {
        var header: String?
        var widgets: [Lossy<CardWidgetDTO>]?
    }

    struct CardWidgetDTO: Decodable, Sendable {
        struct TextParagraph: Decodable, Sendable {
            var text: String?
        }
        struct Labeled: Decodable, Sendable {
            var topLabel: String?
            var bottomLabel: String?
            var content: String?
            var text: String?
            var button: Lossy<ButtonDTO>?
        }
        struct ButtonList: Decodable, Sendable {
            var buttons: [Lossy<ButtonDTO>]?
        }
        struct Image: Decodable, Sendable {
            var imageUrl: String?
            var altText: String?
        }
        struct Columns: Decodable, Sendable {
            struct Column: Decodable, Sendable {
                var widgets: [Lossy<CardWidgetDTO>]?
            }
            var columnItems: [Lossy<Column>]?
        }

        var textParagraph: TextParagraph?
        var keyValue: Labeled?
        var decoratedText: Labeled?
        var buttons: [Lossy<ButtonDTO>]?
        var buttonList: ButtonList?
        var image: Image?
        var divider: Ignored?
        var columns: Columns?
    }

    /// Covers v2 buttons and both v1 forms (`textButton`, `imageButton`).
    struct ButtonDTO: Decodable, Sendable {
        struct OnClick: Decodable, Sendable {
            struct OpenLink: Decodable, Sendable {
                var url: String?
            }
            var openLink: OpenLink?
        }
        struct Inner: Decodable, Sendable {
            var text: String?
            var name: String?
            var onClick: OnClick?
        }

        var text: String?
        var onClick: OnClick?
        var textButton: Inner?
        var imageButton: Inner?
    }
}

enum CardLimits {
    static let cardsPerMessage = 10
    static let sectionsPerCard = 20
    static let widgetsPerCard = 60
    static let buttonsPerWidget = 8
    static let columnDepth = 2
    static let charactersPerCard = 16_000
    static let titleLength = 200
    static let textLength = 4_000
    static let buttonLength = 100
}

/// Converts decoded cards into the domain model within a per-card character budget.
private struct CardBuilder {
    var budget = CardLimits.charactersPerCard
    var widgetCount = 0

    mutating func clean(_ raw: String?, limit: Int) -> String? {
        guard let raw, budget > 0 else { return nil }
        let plain = CardHTML.plain(raw, limit: min(limit, budget))
        guard !plain.isEmpty else { return nil }
        budget -= plain.count
        return plain
    }

    mutating func makeButton(_ dto: Wire.ButtonDTO) -> CardButton? {
        let inner = dto.textButton ?? dto.imageButton
        let rawURL = (dto.onClick ?? inner?.onClick)?.openLink?.url
        let label = dto.text ?? inner?.text ?? inner?.name
        guard let label = clean(label, limit: CardLimits.buttonLength) else { return nil }
        return CardButton(text: label, url: Mapping.webURL(rawURL, httpsOnly: true))
    }

    mutating func makeButtons(_ list: [Lossy<Wire.ButtonDTO>]?) -> [CardWidget] {
        let mapped = (list ?? []).prefix(CardLimits.buttonsPerWidget).compactMap { $0.value.flatMap { makeButton($0) } }
        return mapped.isEmpty ? [] : [.buttons(mapped)]
    }

    mutating func widgets(_ dto: Wire.CardWidgetDTO, depth: Int = 0) -> [CardWidget] {
        guard widgetCount < CardLimits.widgetsPerCard else { return [] }
        var result: [CardWidget] = []
        if let paragraph = dto.textParagraph {
            if let text = clean(paragraph.text, limit: CardLimits.textLength) { result.append(.text(text)) }
        } else if let labeled = dto.keyValue ?? dto.decoratedText {
            let top = clean(labeled.topLabel, limit: CardLimits.titleLength)
            let content = clean(labeled.content ?? labeled.text, limit: CardLimits.textLength)
            let bottom = clean(labeled.bottomLabel, limit: CardLimits.titleLength)
            if content != nil || top != nil || bottom != nil {
                result.append(.keyValue(top: top, content: content ?? "", bottom: bottom))
            }
            if let button = labeled.button?.value.flatMap({ makeButton($0) }) { result.append(.buttons([button])) }
        } else if let list = dto.buttons ?? dto.buttonList?.buttons {
            result += makeButtons(list)
        } else if let image = dto.image {
            result.append(.image(alt: clean(image.altText, limit: CardLimits.titleLength)))
        } else if dto.divider != nil {
            result.append(.divider)
        } else if let columns = dto.columns, depth < CardLimits.columnDepth {
            for column in columns.columnItems ?? [] {
                for widget in column.value?.widgets ?? [] {
                    if let widget = widget.value { result += widgets(widget, depth: depth + 1) }
                }
            }
        }
        widgetCount += result.count
        return result
    }

    mutating func card(_ dto: Wire.CardDTO) -> Card? {
        let title = clean(dto.header?.value?.title, limit: CardLimits.titleLength)
        let subtitle = clean(dto.header?.value?.subtitle, limit: CardLimits.titleLength)
        var sections: [CardSection] = []
        for section in (dto.sections ?? []).prefix(CardLimits.sectionsPerCard) {
            guard let section = section.value else { continue }
            let header = clean(section.header, limit: CardLimits.titleLength)
            let items = (section.widgets ?? []).flatMap { $0.value.map { widgets($0) } ?? [] }
            if header != nil || !items.isEmpty { sections.append(CardSection(header: header, widgets: items)) }
        }
        guard title != nil || subtitle != nil || !sections.isEmpty else { return nil }
        return Card(title: title, subtitle: subtitle, sections: sections)
    }
}

extension Wire.MessageDTO {
    func domainCards() -> [Card]? {
        let dtos = (cards ?? []).compactMap(\.value) + (cardsV2 ?? []).compactMap { $0.value?.card?.value }
        let mapped = dtos.prefix(CardLimits.cardsPerMessage).compactMap { dto -> Card? in
            var builder = CardBuilder()
            return builder.card(dto)
        }
        return mapped.isEmpty ? nil : mapped
    }
}

/// Converts the limited HTML in card text to plain text.
enum CardHTML {
    static func plain(_ html: String, limit: Int) -> String {
        let input = Array(html.unicodeScalars.prefix(limit * 4))
        var output = String.UnicodeScalarView()
        var newlines = 0
        func append(_ scalar: Unicode.Scalar) {
            if scalar == "\n" {
                guard !output.isEmpty, newlines < 2 else { return }
                newlines += 1
            } else {
                newlines = 0
            }
            output.append(scalar)
        }
        var index = 0
        while index < input.count {
            let scalar = input[index]
            if scalar == "<", let close = tagEnd(input, from: index) {
                let name = tagName(input[(index + 1)..<close])
                if name == "br" || (blockTags.contains(name) && newlines == 0) { append("\n") }
                index = close + 1
            } else if scalar == "&", let (decoded, next) = entity(input, from: index) {
                append(decoded)
                index = next
            } else {
                append(scalar)
                index += 1
            }
        }
        let text = String(output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    private static let blockTags: Set<String> = [
        "br", "p", "div", "li", "ul", "ol", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "table", "blockquote",
    ]

    /// A tag opens with `<` and a letter, `/` or `!`; anything else is literal text.
    private static func tagEnd(_ input: [Unicode.Scalar], from start: Int) -> Int? {
        guard start + 1 < input.count else { return nil }
        let first = input[start + 1]
        guard first == "/" || first == "!" || (first.isASCII && first.properties.isAlphabetic) else { return nil }
        let limit = min(input.count, start + 1_000)
        return input[(start + 1)..<limit].firstIndex(of: ">")
    }

    private static func tagName(_ body: ArraySlice<Unicode.Scalar>) -> String {
        var name = ""
        for scalar in body.drop(while: { $0 == "/" }) {
            guard scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) else { break }
            name.unicodeScalars.append(scalar)
        }
        return name.lowercased()
    }

    private static let named: [String: Unicode.Scalar] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
    ]

    private static func entity(_ input: [Unicode.Scalar], from start: Int) -> (Unicode.Scalar, Int)? {
        let limit = min(input.count, start + 10)
        guard let semicolon = input[(start + 1)..<limit].firstIndex(of: ";") else { return nil }
        var body = String.UnicodeScalarView()
        body.append(contentsOf: input[(start + 1)..<semicolon])
        let name = String(body)
        if let scalar = named[name] { return (scalar, semicolon + 1) }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let value =
            digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return (scalar, semicolon + 1)
    }
}
