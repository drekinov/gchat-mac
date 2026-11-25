import AppKit

/// The image preview sheet's size: where it opens, how small it can get, and the size it was last left at.
enum PreviewSheetSize {
    static let minimum = CGSize(width: 480, height: 400)
    static let initial = CGSize(width: 900, height: 640)
    static let defaultsKey = "imagePreviewSize"
    /// Room kept between the sheet and the screen's edges.
    private static let screenInset: CGFloat = 40

    /// The size the preview opens at: the one it was last left at, or `initial`, kept within `screen`.
    static func load(from defaults: UserDefaults, screen: CGSize?) -> CGSize {
        let stored = defaults.string(forKey: defaultsKey).map(NSSizeFromString)
        return clamped(stored.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? initial, screen: screen)
    }

    /// At least `minimum`; no larger than `screen` less a margin, when the screen is known.
    static func clamped(_ size: CGSize, screen: CGSize?) -> CGSize {
        var width = size.width
        var height = size.height
        if let screen {
            width = min(width, screen.width - screenInset)
            height = min(height, screen.height - screenInset)
        }
        return CGSize(width: max(width, minimum.width), height: max(height, minimum.height))
    }

    /// Remembers `size` for the next preview. A size below the minimum isn't a real one, so it's ignored.
    static func save(_ size: CGSize, to defaults: UserDefaults) {
        guard size.width >= minimum.width, size.height >= minimum.height else { return }
        defaults.set(NSStringFromSize(size), forKey: defaultsKey)
    }
}

/// How many thumbnails the preview's strip shows: fewer as the sheet narrows, so the strip and the zoom controls
/// always fit side by side, and none at the narrowest, where ‹ and › remain.
enum ImagePreviewStrip {
    static func length(forWidth width: CGFloat) -> Int {
        switch width {
        case 900...: 7
        case 700...: 5
        case 560...: 3
        default: 0
        }
    }
}

/// The preview's action error, counted each time one is shown, so the same message shown again (an action that
/// fails twice) restarts its fade instead of ending with the first one's.
struct PreviewActionError: Equatable {
    private(set) var text: String?
    private(set) var shown = 0

    init(_ text: String? = nil) { show(text) }

    /// Shows `text`, or clears the error when it's nil (an action that succeeded).
    mutating func show(_ text: String?) {
        self.text = text
        if text != nil { shown += 1 }
    }

    mutating func clear() { text = nil }
}
