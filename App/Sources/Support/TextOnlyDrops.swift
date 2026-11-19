import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Keeps a `TextEditor`'s text view from taking file and image drags, so they reach the enclosing drop destination
/// and attach. A plain `NSTextView` accepts any file drag and types the file's path, and as the innermost view it
/// gets the drag before SwiftUI can. Dragged text still drops into the editor. Use as the editor's background.
struct TextOnlyDrops: NSViewRepresentable {
    func makeNSView(context: Context) -> Finder { Finder() }
    func updateNSView(_ view: Finder, context: Context) { view.scheduleApply() }
    static func dismantleNSView(_ view: Finder, coordinator: ()) { view.tearDown() }

    /// Locates the text view laid out under it; it never takes clicks or drags itself.
    final class Finder: NSView {
        private weak var textView: NSTextView?
        private var pending: Task<Void, Never>?
        private var keyObserver: (any NSObjectProtocol)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            textView = nil
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            keyObserver = window.map { window in
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleApply() }
                }
            }
            scheduleApply()
        }

        // A resize is when the text view re-registers its drag types.
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            scheduleApply()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            scheduleApply()
        }

        /// Runs after the current update. The text view registers its drag types about half a second after it
        /// appears, so a check that finds nothing to filter yet is repeated for a few seconds. A check already
        /// running sees the latest layout on its next attempt, so layout bursts share one.
        func scheduleApply() {
            guard pending == nil else { return }
            pending = Task { [weak self] in
                defer { self?.pending = nil }
                for attempt in 0..<50 {
                    if attempt > 0 { try? await Task.sleep(for: .milliseconds(100)) }
                    guard !Task.isCancelled, let self, window != nil else { return }
                    if apply() { return }
                }
            }
        }

        func tearDown() {
            pending?.cancel()
            pending = nil
            if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
            keyObserver = nil
        }

        /// `true` once the text view is found and takes only text drags.
        private func apply() -> Bool {
            if textView?.window !== window { textView = nil }
            if textView == nil { textView = locate() }
            guard let textView else { return false }
            return TextOnlyDrops.restrict(textView)
        }

        /// The text view whose scroll view contains this view's centre, searched from the nearest ancestors out.
        private func locate() -> NSTextView? {
            guard window != nil, !bounds.isEmpty else { return nil }
            let frame = convert(bounds, to: nil)
            let centre = NSPoint(x: frame.midX, y: frame.midY)
            var ancestor = superview
            while let current = ancestor {
                if let match = Self.textView(in: current, containing: centre) { return match }
                ancestor = current.superview
            }
            return nil
        }

        private static func textView(in view: NSView, containing point: NSPoint) -> NSTextView? {
            if let textView = view as? NSTextView {
                let container = textView.enclosingScrollView ?? textView
                if container.convert(container.bounds, to: nil).contains(point) { return textView }
            }
            for subview in view.subviews {
                if let match = textView(in: subview, containing: point) { return match }
            }
            return nil
        }
    }

    /// `false` while the text view hasn't registered any drag types yet.
    @discardableResult
    static func restrict(_ textView: NSTextView) -> Bool {
        let registered = textView.registeredDraggedTypes
        guard !registered.isEmpty else { return false }
        let kept = registered.filter(isText)
        if kept.count != registered.count {
            textView.unregisterDraggedTypes()
            textView.registerForDraggedTypes(kept)
        }
        return true
    }

    /// Text views register mostly legacy type names, which `UTType` doesn't know.
    static let legacyText: Set<String> = [
        "NSStringPboardType", "NeXT Rich Text Format v1.0 pasteboard type", "Apple HTML pasteboard type",
        "NeXT font pasteboard type", "NeXT ruler pasteboard type", "NSColor pasteboard type",
    ]

    /// Plain and styled text, fonts and colours; not file names, file promises, URLs, images or RTFD (which can
    /// carry files).
    static func isText(_ type: NSPasteboard.PasteboardType) -> Bool {
        if legacyText.contains(type.rawValue) { return true }
        guard let uti = UTType(type.rawValue) else { return false }
        return uti.conforms(to: .text) && !uti.conforms(to: .rtfd) && !uti.conforms(to: .flatRTFD)
    }
}
