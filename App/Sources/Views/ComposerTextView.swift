import AppKit
import ChatText
import SwiftUI

/// How a change to the composer's text came about, which decides how mention ranges follow it.
enum ComposerChange {
    /// Typing, deleting, pasting or dropping: mentions follow a diff of the text.
    case typed
    /// Undo or redo: mentions come back from memory where they can.
    case undo
    /// Edits the composer made itself, after moving the mentions.
    case edits
}

enum ComposerCommand {
    case send(shift: Bool)
    case tab, up, down, escape
}

/// Lets the composer edit through its text view, so its edits join the text view's undo stack.
@MainActor
final class ComposerTextController {
    fileprivate weak var coordinator: ComposerTextView.Coordinator?

    var isComposing: Bool { coordinator?.textView?.hasMarkedText() ?? false }

    /// Whether `perform` would apply now: the text view is editable and not composing. Before the view catches
    /// up with the composer, edits go straight to the composer's text instead.
    var canEdit: Bool {
        guard let textView = coordinator?.textView else { return false }
        return textView.isEditable && !textView.hasMarkedText()
    }

    /// Applies sorted, non-overlapping edits as one undoable change.
    func perform(_ edits: [TextEdit], selection: Range<Int>) {
        coordinator?.perform(edits, selection: selection)
    }

    #if DEBUG
        var textView: NSTextView? { coordinator?.textView }
    #endif
}

/// The composer's field: a plain-text `NSTextView` that styles its Chat markup in place.
struct ComposerTextView: NSViewRepresentable {
    let text: String
    @Binding var selection: Range<Int>?
    @Binding var focused: Bool
    let editable: Bool
    let controller: ComposerTextController
    let onChange: (String, ComposerChange) -> Void
    let onCommand: (ComposerCommand) -> Bool
    let onFormat: (FormatAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        let textView = ComposerNSTextView(usingTextLayoutManager: false)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 5
        textView.textContainerInset = .zero
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.allowsUndo = true
        textView.font = ComposerStyle.font
        textView.typingAttributes = ComposerStyle.base
        textView.defaultParagraphStyle = ComposerStyle.paragraph
        textView.setAccessibilityLabel("Message")
        scroll.documentView = textView
        context.coordinator.attach(textView, parent: self)
        controller.coordinator = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        controller.coordinator = context.coordinator
        context.coordinator.sync(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        fileprivate private(set) weak var textView: ComposerNSTextView?
        private var parent: ComposerTextView?
        private let undo = UndoManager()
        /// The text and selection SwiftUI last heard about or set, so pushes happen only on real changes.
        private var shown = ""
        private var shownSelection: Range<Int>?
        private var pending: ComposerChange?
        private var syncing = false
        private var hadFence = false
        private var deferred: NSRange?
        private var focusQueued = false

        fileprivate func attach(_ textView: ComposerNSTextView, parent: ComposerTextView) {
            self.textView = textView
            textView.delegate = self
            textView.textStorage?.delegate = self
            textView.onFocus = { [weak self] focused in self?.focusChanged(focused) }
            textView.onWindow = { [weak self] in self?.queueFocus() }
            textView.onFormat = { [weak self] action in self?.parent?.onFormat(action) }
            sync(parent)
        }

        fileprivate func sync(_ parent: ComposerTextView) {
            self.parent = parent
            guard let textView, let storage = textView.textStorage else { return }
            syncing = true
            defer { syncing = false }
            if textView.isEditable != parent.editable { textView.isEditable = parent.editable }
            let composing = textView.hasMarkedText()
            if parent.text != shown, !composing {
                shown = parent.text
                storage.setAttributedString(NSAttributedString(string: parent.text, attributes: ComposerStyle.base))
                undo.removeAllActions()
                shownSelection = nil
            }
            if let selection = parent.selection, selection != shownSelection, !composing {
                shownSelection = selection
                let length = storage.length
                let lower = min(max(selection.lowerBound, 0), length)
                textView.setSelectedRange(NSRange(location: lower, length: min(selection.upperBound, length) - lower))
            }
            if parent.focused, textView.window?.firstResponder !== textView { queueFocus() }
        }

        /// Focus moves after the current update; a view not yet in a window takes it when it gets one.
        private func queueFocus() {
            guard !focusQueued, parent?.focused == true else { return }
            focusQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                focusQueued = false
                guard parent?.focused == true, let textView, let window = textView.window,
                    window.firstResponder !== textView
                else { return }
                window.makeFirstResponder(textView)
            }
        }

        private func focusChanged(_ focused: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let parent, parent.focused != focused else { return }
                parent.focused = focused
            }
        }

        fileprivate func perform(_ edits: [TextEdit], selection: Range<Int>) {
            guard let textView, let storage = textView.textStorage, !edits.isEmpty, !textView.hasMarkedText(),
                edits.allSatisfy({ $0.range.lowerBound >= 0 && $0.range.upperBound <= storage.length })
            else { return }
            let ranges = edits.map { NSValue(range: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }
            textView.breakUndoCoalescing()
            guard textView.shouldChangeText(inRanges: ranges, replacementStrings: edits.map(\.replacement)) else {
                return
            }
            pending = .edits
            storage.beginEditing()
            for edit in edits.reversed() {
                storage.replaceCharacters(
                    in: NSRange(location: edit.range.lowerBound, length: edit.range.count), with: edit.replacement)
            }
            storage.endEditing()
            textView.didChangeText()
            pending = nil
            let length = storage.length
            let lower = min(selection.lowerBound, length)
            textView.setSelectedRange(NSRange(location: lower, length: min(selection.upperBound, length) - lower))
            textView.breakUndoCoalescing()
        }

        // MARK: NSTextViewDelegate

        func undoManager(for view: NSTextView) -> UndoManager? { undo }

        func textDidChange(_ notification: Notification) {
            guard let textView, !syncing else { return }
            let value = textView.string
            let change = pending ?? (undo.isUndoing || undo.isRedoing ? .undo : .typed)
            shown = value
            restyleDeferred()
            parent?.onChange(value, change)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView, !syncing else { return }
            let range = textView.selectedRange()
            let selection = range.location..<(range.location + range.length)
            if !textView.hasMarkedText() {
                textView.typingAttributes = ComposerStyle.base
                restyleDeferred()
            }
            guard selection != shownSelection else { return }
            shownSelection = selection
            parent?.selection = selection
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText(), let parent else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                let shift = self.textView?.lastModifiers.contains(.shift) ?? false
                return parent.onCommand(.send(shift: shift))
            case #selector(NSResponder.insertTab(_:)): return parent.onCommand(.tab)
            case #selector(NSResponder.moveUp(_:)): return parent.onCommand(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onCommand(.down)
            case #selector(NSResponder.cancelOperation(_:)): return parent.onCommand(.escape)
            default: return false
            }
        }

        // MARK: NSTextStorageDelegate

        func textStorage(
            _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            if textView?.hasMarkedText() == true {
                deferred = deferred.map { NSUnionRange($0, range) } ?? range
                return
            }
            restyle(textStorage, around: range)
        }

        private func restyleDeferred() {
            guard let range = deferred, let storage = textView?.textStorage, textView?.hasMarkedText() == false
            else { return }
            deferred = nil
            let length = storage.length
            let lower = min(range.location, length)
            storage.beginEditing()
            restyle(storage, around: NSRange(location: lower, length: min(NSMaxRange(range), length) - lower))
            storage.endEditing()
        }

        /// Restyles the lines an edit touched, or everything while the text has or just lost a fence.
        private func restyle(_ storage: NSTextStorage, around edited: NSRange) {
            let string = storage.mutableString
            let fence = string.range(of: "```").location != NSNotFound
            let reach = NSRange(
                location: edited.location, length: min(edited.length + 1, string.length - edited.location))
            let target = fence || hadFence ? NSRange(location: 0, length: string.length) : string.lineRange(for: reach)
            hadFence = fence
            guard target.length > 0 else { return }
            storage.addAttributes(ComposerStyle.base, range: target)
            storage.removeAttribute(.backgroundColor, range: target)
            storage.removeAttribute(.strikethroughStyle, range: target)
            for run in ChatMarkup.composerRuns(string.substring(with: target)) {
                storage.addAttributes(
                    ComposerStyle.attributes(run),
                    range: NSRange(location: target.location + run.range.lowerBound, length: run.range.count))
            }
        }
    }
}

/// The composer's text view: takes only text drags, so files reach the composer's drop destination, and reports
/// focus and the modifiers of the last key.
final class ComposerNSTextView: NSTextView {
    var onFocus: ((Bool) -> Void)?
    var onWindow: (() -> Void)?
    var onFormat: ((FormatAction) -> Void)?
    private(set) var lastModifiers: NSEvent.ModifierFlags = []

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes.filter(TextOnlyDrops.isText)
    }

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        super.registerForDraggedTypes(newTypes.filter(TextOnlyDrops.isText))
    }

    /// Formats the selection the way the format bar's button does.
    func format(_ action: FormatAction) { onFormat?(action) }

    override func keyDown(with event: NSEvent) {
        lastModifiers = event.modifierFlags
        super.keyDown(with: event)
        lastModifiers = []
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocus?(false) }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindow?() }
    }
}

/// The composer's text attributes. Every run keeps the body size and a 16 pt line, so the editor's height model
/// holds for code and emoji too.
@MainActor
enum ComposerStyle {
    static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = ComposerView.lineHeight
        style.maximumLineHeight = ComposerView.lineHeight
        return style
    }()
    static let base: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph,
    ]
    static let marker = NSColor.tertiaryLabelColor
    static let codeTint = Theme.dynamicNS(light: 0x00_0000, dark: 0xFF_FFFF, lightAlpha: 0.07, darkAlpha: 0.09)
    static let link = Theme.dynamicNS(light: 0x4A_6382, dark: 0xA4_B1C0)
    private static var fonts: [UInt8: NSFont] = [:]

    static func attributes(_ run: ComposerRun) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font(run.style)]
        if run.style.contains(.code) { attributes[.backgroundColor] = codeTint }
        if run.style.contains(.strikethrough), run.kind != .marker {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        switch run.kind {
        case .marker: attributes[.foregroundColor] = marker
        case .link: attributes[.foregroundColor] = link
        case .text: break
        }
        return attributes
    }

    static func font(_ style: Span.Style) -> NSFont {
        let key = style.intersection([.bold, .italic, .code]).rawValue
        if let cached = fonts[key] { return cached }
        let bold = style.contains(.bold)
        var made =
            style.contains(.code)
            ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: bold ? .bold : .regular)
            : bold ? NSFont.boldSystemFont(ofSize: font.pointSize) : font
        if style.contains(.italic) { made = NSFontManager.shared.convert(made, toHaveTrait: .italicFontMask) }
        fonts[key] = made
        return made
    }
}
