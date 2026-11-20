import AppKit
import SwiftUI

/// The preview's zoom, shared by its toolbar and the scroll view. The view reports every change back, whichever
/// way it was made (buttons, keys, pinch, ⌘-scroll, double-click), so the percentage shown never goes stale.
@MainActor @Observable
final class ZoomController {
    /// The levels the zoom buttons and keys step through.
    static let steps: [CGFloat] = [0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 6, 8]
    static let tolerance: CGFloat = 0.002

    /// 1 is actual size: one image pixel per screen pixel.
    private(set) var magnification: CGFloat = 1
    private(set) var isFit = true
    /// Set once the person zooms in any way, so the zoom hint can go.
    private(set) var hasZoomed = false
    @ObservationIgnored fileprivate weak var view: ZoomScrollView?

    var canZoomIn: Bool { magnification < Self.steps[Self.steps.count - 1] - Self.tolerance }
    var canZoomOut: Bool { magnification > Self.steps[0] + Self.tolerance }

    func zoomIn() { view?.step(in: true) }
    func zoomOut() { view?.step(in: false) }
    func actualSize() { view?.zoom(to: 1) }
    func fit() { view?.zoomToFit() }

    fileprivate func attach(_ view: ZoomScrollView) { self.view = view }

    fileprivate func detach(_ view: ZoomScrollView) {
        if self.view === view { self.view = nil }
    }

    /// Only real changes are written, so scrolling (which moves the bounds but not the zoom) costs no view updates.
    fileprivate func report(magnification: CGFloat, isFit: Bool) {
        if abs(self.magnification - magnification) > 0.0005 { self.magnification = magnification }
        if self.isFit != isFit { self.isFit = isFit }
    }

    fileprivate func noteZoomed() {
        if !hasZoomed { hasZoomed = true }
    }
}

/// An image at its natural size (pixels ÷ screen scale), shrunk to fit if larger and never enlarged on open.
/// Pinch or ⌘-scroll to magnify; double-click toggles between fit and 100%.
struct ZoomableImage: NSViewRepresentable {
    let image: CGImage
    var controller: ZoomController?
    /// Clear space kept on each side of a fitted image, e.g. for controls floating over its edge.
    var fitMargin = CGSize.zero
    /// Opens at this magnification instead of fitting.
    var startMagnification: CGFloat?

    func makeNSView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView(image: image)
        view.fitMargin = fitMargin
        view.startMagnification = startMagnification
        view.controller = controller
        controller?.attach(view)
        return view
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        view.show(image)
    }

    static func dismantleNSView(_ view: ZoomScrollView, coordinator: ()) {
        view.controller?.detach(view)
    }
}

final class ZoomScrollView: NSScrollView {
    private let imageView = NSImageView()
    private var image: CGImage
    private var fitted = false
    /// The size the zoom was last laid out for, so a resize keeps a fitted image fitted.
    private var laidOutSize = NSSize.zero
    var fitMargin = CGSize.zero
    var startMagnification: CGFloat?
    weak var controller: ZoomController?

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        contentView = CenteringClipView()
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.05
        maxMagnification = 8
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.magnificationFilter = .nearest
        // A soft shadow lifts the image off the stage; `layout` gives it an explicit path, so zooming stays cheap.
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        imageView.shadow = shadow
        documentView = imageView
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleZoom))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
        // Magnifying resizes the clip view's bounds, so this sees pinch, scroll and animated zooms alike.
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func show(_ newImage: CGImage) {
        guard newImage !== image else { return }
        image = newImage
        fitted = false
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if !fitted {
            let scale = window?.backingScaleFactor ?? 2
            let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            imageView.image = NSImage(cgImage: image, size: size)
            imageView.frame = NSRect(origin: .zero, size: size)
            imageView.layer?.shadowPath = CGPath(rect: imageView.bounds, transform: nil)
            fitted = true
            laidOutSize = bounds.size
            if let start = startMagnification {
                startMagnification = nil
                setMagnification(start, centeredAt: NSPoint(x: size.width / 2, y: size.height / 2))
            } else {
                magnification = fitMagnification(for: bounds.size)
            }
        } else if bounds.size != laidOutSize {
            let wasFit = abs(magnification - fitMagnification(for: laidOutSize)) < ZoomController.tolerance
            laidOutSize = bounds.size
            if wasFit { magnification = fitMagnification(for: bounds.size) }
        }
        report()
    }

    private func fitMagnification(for size: NSSize) -> CGFloat {
        let image = imageView.frame.size
        guard image.width > 0, image.height > 0 else { return 1 }
        let width = max(size.width - 2 * fitMargin.width, 1)
        let height = max(size.height - 2 * fitMargin.height, 1)
        return min(1, width / image.width, height / image.height)
    }

    @objc private func boundsChanged(_ notification: Notification) {
        report()
    }

    private func report() {
        guard fitted else { return }
        let fit = fitMagnification(for: bounds.size)
        controller?.report(magnification: magnification, isFit: abs(magnification - fit) < ZoomController.tolerance)
    }

    /// Zooms to the next step up or down, keeping the middle of the view in place.
    func step(in zoomingIn: Bool) {
        let current = magnification
        let tolerance = ZoomController.tolerance
        let next =
            zoomingIn
            ? ZoomController.steps.first { $0 > current + tolerance }
            : ZoomController.steps.last { $0 < current - tolerance }
        if let next { zoom(to: next) }
    }

    func zoomToFit() {
        zoom(to: fitMagnification(for: bounds.size))
    }

    func zoom(to target: CGFloat) {
        controller?.noteZoomed()
        let middle = NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        animator().setMagnification(target, centeredAt: middle)
    }

    /// ⌘-scroll zooms around the pointer, so mouse users can zoom without a trackpad; plain scrolling still pans.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        // Pushing the wheel or fingers away zooms in, whichever scrolling direction is set in System Settings.
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        guard delta != 0 else { return }
        // Trackpads report points and wheels report lines: about 1% per point, 10% per notch.
        let factor = event.hasPreciseScrollingDeltas ? exp(delta * 0.01) : pow(1.1, delta)
        controller?.noteZoomed()
        setMagnification(magnification * factor, centeredAt: contentView.convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        controller?.noteZoomed()
        super.magnify(with: event)
    }

    @objc private func toggleZoom(_ recognizer: NSClickGestureRecognizer) {
        controller?.noteZoomed()
        let target: CGFloat = abs(magnification - 1) < 0.01 ? fitMagnification(for: bounds.size) : 1
        let point = contentView.convert(recognizer.location(in: self), from: self)
        animator().setMagnification(target, centeredAt: point)
    }
}

/// Keeps a document smaller than the visible area centered instead of pinned to the bottom-left.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
