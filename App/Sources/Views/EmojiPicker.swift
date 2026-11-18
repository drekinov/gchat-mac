import AppKit
import ChatModel
import GoogleChat
import SwiftUI

enum EmojiPick {
    case unicode(String)
    case custom(CustomEmoji)

    /// The text a composer inserts for this pick.
    var insertionText: String {
        switch self {
        case .unicode(let glyph): glyph
        case .custom(let emoji): ":\(EmojiPick.bareShortcode(emoji.shortcode)):"
        }
    }

    var reaction: Emoji {
        switch self {
        case .unicode(let glyph): .unicode(glyph)
        case .custom(let emoji): .custom(emoji.name, shortcode: emoji.shortcode)
        }
    }

    static func bareShortcode(_ shortcode: String) -> String {
        RemoteText.title(shortcode).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    }
}

private struct PickCell: Identifiable {
    let id: String
    let pick: EmojiPick
    let display: String
    let label: String
    let isCustom: Bool
}

private struct PickSection: Identifiable {
    let id: String
    let title: String
    let columns: Int
    let cells: [PickCell]
}

private enum PickRow: Identifiable {
    case header(id: String, title: String)
    case cells(id: String, cells: [PickCell], custom: Bool)

    var id: String {
        switch self {
        case .header(let id, _), .cells(let id, _, _): id
        }
    }
}

struct EmojiPicker: View {
    var customEmojis: [CustomEmoji] = []
    var onPick: (EmojiPick) -> Void
    var onClose: () -> Void = {}

    @AppStorage("emojiRecents") private var recentsJSON = ""
    @AppStorage("emojiSkinTone") private var tone = 0
    @State private var query: String
    @State private var cursor = Cursor(row: 0, column: 0)
    @FocusState private var focused: Bool

    init(
        customEmojis: [CustomEmoji] = [], initialQuery: String = "", onPick: @escaping (EmojiPick) -> Void,
        onClose: @escaping () -> Void = {}
    ) {
        self.customEmojis = customEmojis
        self.onPick = onPick
        self.onClose = onClose
        _query = State(initialValue: initialQuery)
    }

    private struct Cursor: Equatable {
        var row: Int
        var column: Int
    }

    private static let recentLimit = 16

    var body: some View {
        let layout = rows()
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search emoji", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { pickCurrent(layout.cellRows) }
                    .onKeyPress(.downArrow) { move(.down, layout.cellRows) }
                    .onKeyPress(.upArrow) { move(.up, layout.cellRows) }
                    .onKeyPress(.rightArrow) { query.isEmpty ? move(.right, layout.cellRows) : .ignored }
                    .onKeyPress(.leftArrow) { query.isEmpty ? move(.left, layout.cellRows) : .ignored }
            }
            .padding(10)
            toneSelector
            Divider()
            list(layout)
            Divider()
            HStack {
                Button("Emoji & Symbols…") {
                    onClose()
                    NSApplication.shared.orderFrontCharacterPalette(nil)
                }
                .buttonStyle(.link)
                .font(.callout)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .frame(width: 340, height: 440)
        .onChange(of: query) { cursor = Cursor(row: 0, column: 0) }
        .onExitCommand(perform: onClose)
        .task { focused = true }
    }

    // MARK: Layout

    private var toneSelector: some View {
        HStack(spacing: 4) {
            Text("Skin tone").font(.caption).foregroundStyle(.secondary)
            Spacer()
            ForEach(0...5, id: \.self) { value in
                Button {
                    tone = value
                } label: {
                    Text(EmojiData.item(for: "✋")?.glyph(tone: value) ?? "✋")
                        .font(.system(size: 14))
                        .frame(width: 24, height: 22)
                        .background(
                            tone == value ? Color.accentColor.opacity(0.25) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(value == 0 ? "Default skin tone" : "Skin tone \(value)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func list(_ layout: (rows: [PickRow], cellRows: [[PickCell]])) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(layout.rows.enumerated()), id: \.element.id) { _, row in
                        switch row {
                        case .header(_, let title):
                            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.top, 8).padding(.bottom, 2)
                        case .cells(_, let cells, let custom):
                            HStack(spacing: 2) {
                                ForEach(cells) { cell in
                                    cellButton(
                                        cell, custom: custom, highlighted: cell.id == highlightedID(layout.cellRows))
                                }
                            }
                            .id(row.id)
                        }
                    }
                    if layout.cellRows.isEmpty {
                        Text("No matching emoji").foregroundStyle(.secondary).padding(20)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .onChange(of: cursor) {
                if let id = highlightedRowID(layout.rows, layout.cellRows) { proxy.scrollTo(id) }
            }
        }
    }

    private func cellButton(_ cell: PickCell, custom: Bool, highlighted: Bool) -> some View {
        Button {
            pick(cell)
        } label: {
            Group {
                if custom {
                    Text(cell.display).font(.caption.monospaced()).foregroundStyle(
                        Color(red: 0.50, green: 0.30, blue: 0.80)
                    )
                    .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(cell.display).font(.system(size: 22))
                }
            }
            .frame(width: custom ? 104 : 36, height: 34)
            .background(highlighted ? Color.accentColor.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(cell.label)
        .accessibilityLabel(cell.label)
    }

    // MARK: Content

    private func sections() -> [PickSection] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            var cells = EmojiData.all.filter { $0.matches(needle) }.map { cell(for: $0) }
            cells += customEmojis.filter { $0.shortcode.localizedCaseInsensitiveContains(needle) }.map(customCell)
            return [PickSection(id: "results", title: "Results", columns: 8, cells: cells)]
        }
        var result: [PickSection] = []
        let recent = recents().compactMap(recentCell)
        if !recent.isEmpty {
            result.append(PickSection(id: "recent", title: "Frequently used", columns: 8, cells: recent))
        }
        if !customEmojis.isEmpty {
            result.append(
                PickSection(id: "custom", title: "Custom", columns: 3, cells: customEmojis.map(customCell)))
        }
        for category in EmojiData.categories {
            result.append(
                PickSection(
                    id: category.id, title: category.title, columns: 8, cells: category.items.map { cell(for: $0) }))
        }
        return result
    }

    private func rows() -> (rows: [PickRow], cellRows: [[PickCell]]) {
        var rows: [PickRow] = []
        var cellRows: [[PickCell]] = []
        for section in sections() where !section.cells.isEmpty {
            rows.append(.header(id: "h-\(section.id)", title: section.title))
            var start = 0
            while start < section.cells.count {
                let chunk = Array(section.cells[start..<min(start + section.columns, section.cells.count)])
                rows.append(.cells(id: "\(section.id)-\(start)", cells: chunk, custom: section.id == "custom"))
                cellRows.append(chunk)
                start += section.columns
            }
        }
        return (rows, cellRows)
    }

    private func cell(for item: EmojiItem) -> PickCell {
        let glyph = item.glyph(tone: tone)
        return PickCell(
            id: "u-\(glyph)", pick: .unicode(glyph), display: glyph, label: item.name, isCustom: false)
    }

    private func customCell(_ emoji: CustomEmoji) -> PickCell {
        let name = EmojiPick.bareShortcode(emoji.shortcode)
        return PickCell(
            id: "c-\(emoji.name.rawValue)", pick: .custom(emoji), display: ":\(name):", label: name, isCustom: true)
    }

    private func recentCell(_ entry: String) -> PickCell? {
        if entry.hasPrefix(":") {
            let name = entry.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return customEmojis.first { EmojiPick.bareShortcode($0.shortcode) == name }.map(customCell)
        }
        let label = EmojiData.all.first { $0.glyph(tone: 0) == entry || $0.glyph(tone: tone) == entry }?.name ?? entry
        return PickCell(id: "r-\(entry)", pick: .unicode(entry), display: entry, label: label, isCustom: false)
    }

    // MARK: Recents

    private func recents() -> [String] {
        if let data = recentsJSON.data(using: .utf8), let saved = try? JSONDecoder().decode([String].self, from: data),
            !saved.isEmpty
        {
            return saved
        }
        return EmojiData.defaultRecents
    }

    private func remember(_ entry: String) {
        var list = recents().filter { $0 != entry }
        list.insert(entry, at: 0)
        list = Array(list.prefix(Self.recentLimit))
        if let data = try? JSONEncoder().encode(list), let text = String(data: data, encoding: .utf8) {
            recentsJSON = text
        }
    }

    // MARK: Keyboard

    private enum Direction { case up, down, left, right }

    private func move(_ direction: Direction, _ cellRows: [[PickCell]]) -> KeyPress.Result {
        guard !cellRows.isEmpty else { return .handled }
        var next = cursor
        next.row = min(next.row, cellRows.count - 1)
        switch direction {
        case .down:
            next.row = min(next.row + 1, cellRows.count - 1)
        case .up:
            next.row = max(next.row - 1, 0)
        case .right:
            if next.column + 1 < cellRows[next.row].count {
                next.column += 1
            } else if next.row + 1 < cellRows.count {
                next.row += 1
                next.column = 0
            }
        case .left:
            if next.column > 0 {
                next.column -= 1
            } else if next.row > 0 {
                next.row -= 1
                next.column = cellRows[next.row].count - 1
            }
        }
        next.column = min(next.column, cellRows[next.row].count - 1)
        cursor = next
        return .handled
    }

    private func highlightedID(_ cellRows: [[PickCell]]) -> String? {
        guard cellRows.indices.contains(cursor.row), cellRows[cursor.row].indices.contains(cursor.column) else {
            return nil
        }
        return cellRows[cursor.row][cursor.column].id
    }

    private func highlightedRowID(_ rows: [PickRow], _ cellRows: [[PickCell]]) -> String? {
        guard let first = cellRows[safe: cursor.row]?.first else { return nil }
        for row in rows {
            if case .cells(let id, let cells, _) = row, cells.first?.id == first.id { return id }
        }
        return nil
    }

    private func pickCurrent(_ cellRows: [[PickCell]]) {
        guard cellRows.indices.contains(cursor.row), cellRows[cursor.row].indices.contains(cursor.column) else {
            return
        }
        pick(cellRows[cursor.row][cursor.column])
    }

    private func pick(_ cell: PickCell) {
        switch cell.pick {
        case .unicode(let glyph): remember(glyph)
        case .custom(let emoji): remember(":\(EmojiPick.bareShortcode(emoji.shortcode)):")
        }
        onPick(cell.pick)
        onClose()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
