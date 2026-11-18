import AppKit
import SwiftUI

/// An image at its natural size (pixels ÷ screen scale), shrunk to fit if larger and never enlarged on open.
/// Pinch or scroll-zoom to magnify; double-click toggles between fit and 100%.
struct ZoomableImage: NSViewRepresentable {
    let image: CGImage

    func makeNSView(context: Context) -> ZoomScrollView {
        ZoomScrollView(image: image)
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        view.show(image)
    }
}

final class ZoomScrollView: NSScrollView {
    private let imageView = NSImageView()
    private var image: CGImage
    private var fitted = false

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
        documentView = imageView
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleZoom))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
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
        guard !fitted, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        imageView.image = NSImage(cgImage: image, size: size)
        imageView.frame = NSRect(origin: .zero, size: size)
        fitted = true
        magnification = fitMagnification
    }

    private var fitMagnification: CGFloat {
        let size = imageView.frame.size
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(1, bounds.width / size.width, bounds.height / size.height)
    }

    @objc private func toggleZoom(_ recognizer: NSClickGestureRecognizer) {
        let target: CGFloat = abs(magnification - 1) < 0.01 ? fitMagnification : 1
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
