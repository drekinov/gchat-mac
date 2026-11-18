import Foundation

/// A read-only Google Chat card, reduced to the plain-text structure the app renders.
public struct Card: Hashable, Sendable, Codable {
    public var title: String?
    public var subtitle: String?
    public var sections: [CardSection]

    public init(title: String? = nil, subtitle: String? = nil, sections: [CardSection] = []) {
        self.title = title
        self.subtitle = subtitle
        self.sections = sections
    }

    /// The first line of readable content, for notification and list previews.
    public var summary: String? {
        if let title, !title.isEmpty { return title }
        if let subtitle, !subtitle.isEmpty { return subtitle }
        for widget in sections.lazy.flatMap(\.widgets) {
            switch widget {
            case .text(let text) where !text.isEmpty: return text
            case .keyValue(_, let content, _) where !content.isEmpty: return content
            default: continue
            }
        }
        return nil
    }
}

public struct CardSection: Hashable, Sendable, Codable {
    public var header: String?
    public var widgets: [CardWidget]

    public init(header: String? = nil, widgets: [CardWidget] = []) {
        self.header = header
        self.widgets = widgets
    }
}

public enum CardWidget: Hashable, Sendable, Codable {
    case text(String)
    case keyValue(top: String?, content: String, bottom: String?)
    case buttons([CardButton])
    /// Never loaded; shown as a caption.
    case image(alt: String?)
    case divider
}

public struct CardButton: Hashable, Sendable, Codable {
    public var text: String
    /// `https` only; `nil` for buttons that trigger actions the app can't perform.
    public var url: URL?

    public init(text: String, url: URL? = nil) {
        self.text = text
        self.url = url
    }
}
