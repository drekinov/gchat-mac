import AppKit
import SwiftUI

/// Reports the user scrolling the list behind this view, by wheel, trackpad or scroll bar, while `isWaiting` holds.
///
/// A macOS `List` doesn't report SwiftUI scroll phases, and its offset moves the same way for `scrollTo`, so this looks
/// at the input instead. The event monitor exists only while something is waiting.
struct ManualScrollWatcher: NSViewRepresentable {
    /// Changes when there may be something new to wait for.
    let sequence: Int
    let isWaiting: () -> Bool
    let onScroll: () -> Void

    func makeNSView(context: Context) -> WatcherView { WatcherView() }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.isWaiting = isWaiting
        view.onScroll = onScroll
        if isWaiting() { view.start() } else { view.stop() }
    }

    static func dismantleNSView(_ view: WatcherView, coordinator: ()) { view.stop() }

    final class WatcherView: NSView {
        var isWaiting: () -> Bool = { false }
        var onScroll: () -> Void = {}
        private var monitor: Any?
        /// Whether the trackpad gesture under way began over the list; nil if none began since the monitor started.
        /// AppKit sends a whole gesture to the view under the pointer when it began, even after the list moves.
        private var gestureOnList: Bool?

        // It only watches; every click and scroll goes to the list.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
                self?.inspect(event)
                return event
            }
        }

        func stop() {
            gestureOnList = nil
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        private func inspect(_ event: NSEvent) {
            guard isWaiting() else { return stop() }
            guard scrollsList(event) else { return }
            stop()
            onScroll()
        }

        private func scrollsList(_ event: NSEvent) -> Bool {
            guard event.type == .scrollWheel else { return listView(at: event) is NSScroller }
            // Momentum is left over from a gesture that has already ended.
            guard event.momentumPhase.isEmpty else { return false }
            // A mouse wheel has no phases, and each notch goes to whatever is under the pointer.
            if event.phase.isEmpty { return event.scrollingDeltaY != 0 && listView(at: event) != nil }
            switch event.phase {
            case .began:
                gestureOnList = listView(at: event) != nil
            case .changed:
                break
            case .ended, .cancelled:
                gestureOnList = nil
                return false
            default:
                // A finger resting on the trackpad isn't scrolling.
                return false
            }
            return gestureOnList == true && event.scrollingDeltaY != 0
        }

        /// The view under the event when it belongs to the list, rather than to a reply box nested inside it.
        private func listView(at event: NSEvent) -> NSView? {
            guard let window, event.window === window, let content = window.contentView,
                bounds.contains(convert(event.locationInWindow, from: nil)),
                let hit = content.hitTest(
                    content.superview?.convert(event.locationInWindow, from: nil)
                        ?? event.locationInWindow),
                let scrollView = Self.scrollView(around: hit),
                // A reply box inside the list is a scroll view of its own and keeps the events over it.
                scrollView.superview.flatMap(Self.scrollView(around:)) == nil
            else { return nil }
            return hit
        }

        /// The nearest scroll view at or above `view`. `enclosingScrollView` doesn't reach one from its own scroll bar.
        private static func scrollView(around view: NSView) -> NSScrollView? {
            var current: NSView? = view
            while let candidate = current {
                if let scrollView = candidate as? NSScrollView { return scrollView }
                current = candidate.superview
            }
            return nil
        }
    }
}
