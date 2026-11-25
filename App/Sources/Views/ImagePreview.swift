import AppKit
import ChatModel
import ChatNet
import ChatSync
import SwiftUI
import UniformTypeIdentifiers

/// What the image preview shows: the open conversation's images, stepped through with ← and →, a single image
/// (from search), or a GIF link.
struct PreviewTarget: Identifiable {
    /// Who sent a message and when, for the line under the file name.
    struct Origin {
        var sender: String?
        var time: Timestamp?
        /// The message the image came with, for Show in Chat.
        var message: MessageName?

        init(sender: String? = nil, time: Timestamp? = nil, message: MessageName? = nil) {
            self.sender = sender
            self.time = time
            self.message = message
        }

        init(_ message: Message) {
            self.init(sender: message.sender.displayName, time: message.createTime, message: message.name)
        }
    }

    struct Item {
        let attachment: Attachment
        let origin: Origin
    }

    let id = UUID()
    /// In conversation order; empty for a GIF link.
    let items: [Item]
    /// The item shown first.
    let start: Int
    let gifURL: URL?
    let gifOrigin: Origin
    /// The conversation's name; nil in a direct message, where it would only repeat the sender.
    let place: String?
    let media: MediaLoader

    /// `messages` are searched in order, and the first list that holds the attachment supplies every image the
    /// preview can step to. An attachment found in none of them is shown on its own.
    init(attachment: Attachment, media: MediaLoader, messages: [[Message]] = [], space: SpaceSummary? = nil) {
        var items: [Item] = []
        var start: Int?
        for list in messages where list.contains(where: { $0.attachments.contains(attachment) }) {
            for message in list where !message.isDeleted {
                for candidate in message.attachments where AttachmentIcon.isImage(candidate) {
                    if start == nil, candidate == attachment { start = items.count }
                    items.append(Item(attachment: candidate, origin: Origin(message)))
                }
            }
            break
        }
        if start == nil { items = [Item(attachment: attachment, origin: Origin())] }
        self.items = items
        self.start = start ?? 0
        gifURL = nil
        gifOrigin = Origin()
        place = Self.place(space)
        self.media = media
    }

    init(gifURL: URL, media: MediaLoader, messages: [[Message]] = [], space: SpaceSummary? = nil) {
        items = []
        start = 0
        self.gifURL = gifURL
        gifOrigin = messages.joined().first { $0.gifURLs.contains(gifURL) }.map(Origin.init) ?? Origin()
        place = Self.place(space)
        self.media = media
    }

    private static func place(_ space: SpaceSummary?) -> String? {
        guard let space, space.type != .directMessage else { return nil }
        return space.title
    }

    /// "<sender> in Release 2.4, today at 10:31"; whatever isn't known is left out.
    func byline(_ origin: Origin, now: Date = Date()) -> String? {
        let sender = origin.sender.map(RemoteText.title).flatMap { $0.isEmpty ? nil : $0 }
        let place = place.map(RemoteText.title).flatMap { $0.isEmpty ? nil : $0 }
        var text = sender ?? ""
        if let place { text += text.isEmpty ? "In \(place)" : " in \(place)" }
        if let time = origin.time {
            let when = Self.when(time.date, now: now)
            text += text.isEmpty ? when.prefix(1).uppercased() + when.dropFirst() : ", \(when)"
        }
        return text.isEmpty ? nil : text
    }

    /// "today at 10:31", "yesterday at 16:05" or "Tue 18 Nov at 09:12", with the year when it isn't this year's.
    static func when(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        let clock = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(clock)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "yesterday at \(clock)"
        }
        var day = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { day = day.year() }
        return "\(date.formatted(day)) at \(clock)"
    }
}

/// A Quick Look-style viewer with zoom controls that closes with Space or Escape. Only the image on screen and the
/// strip's few small thumbnails are decoded, and each decode is released as soon as it's no longer shown.
struct ImagePreviewSheet: View {
    let target: PreviewTarget
    /// Opens the first image at this magnification instead of fitting it (for snapshots).
    var startZoom: CGFloat?
    /// Opens showing this action error (for snapshots).
    var startError: String?
    /// Closes the preview and scrolls the conversation to the image's message.
    var onShowInChat: ((MessageName) -> Void)?
    var onClose: () -> Void
    /// Where the size the sheet was last left at is kept.
    private let defaults: UserDefaults

    @Environment(\.displayScale) private var displayScale
    @Environment(\.isSnapshotMode) private var snapshotMode
    @State private var index: Int
    @State private var decoded: DecodedImage?
    @State private var failure: MediaLoadError?
    @State private var actionError = PreviewActionError()
    /// Positions whose file is being exported to open elsewhere.
    @State private var opening: Set<Int> = []
    @State private var copied = false
    /// Counts successful copies, so only the latest one's timer clears "Copied".
    @State private var copies = 0
    @State private var showsHint = true
    @State private var zoom = ZoomController()
    @State private var thumbnails: [Int: DecodedImage] = [:]
    @State private var failedThumbnails: Set<Int> = []
    /// The size the sheet opens at, kept for as long as it's open, so a size saved meanwhile never moves it.
    @State private var openingSize: CGSize
    /// How many thumbnails fit the sheet's width; changes only when a resize crosses a threshold.
    @State private var stripLength: Int
    @FocusState private var focused: Bool

    /// The floating controls' heights, their distance from the sheet's edges, and the clear space a fitted image
    /// keeps at the top and bottom so the controls don't cover it.
    private static let topHeight: CGFloat = 44
    private static let bottomHeight: CGFloat = 46
    private static let edgeInset: CGFloat = 12
    private static let controlsMargin: CGFloat = 64
    private static let thumbnailPixels = 160
    /// A little darker than the window in light mode, so a white screenshot's edges still show.
    private static let stageColor = Theme.dynamic(light: 0xE2_E5E9, dark: 0x15_171A)

    init(
        target: PreviewTarget, startZoom: CGFloat? = nil, startError: String? = nil,
        defaults: UserDefaults = .standard, onShowInChat: ((MessageName) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.target = target
        self.startZoom = startZoom
        self.startError = startError
        _actionError = State(initialValue: PreviewActionError(startError))
        self.defaults = defaults
        self.onShowInChat = onShowInChat
        self.onClose = onClose
        let opening = PreviewSheetSize.load(from: defaults, screen: NSScreen.main?.visibleFrame.size)
        _openingSize = State(initialValue: opening)
        _stripLength = State(initialValue: ImagePreviewStrip.length(forWidth: opening.width))
        _index = State(initialValue: target.start)
    }

    private var current: PreviewTarget.Item? {
        target.items.indices.contains(index) ? target.items[index] : nil
    }

    var body: some View {
        stage
            // A frame with no maximum and fitted sizing is what makes a sheet resizable from its edges.
            .frame(
                minWidth: PreviewSheetSize.minimum.width, idealWidth: openingSize.width, maxWidth: .infinity,
                minHeight: PreviewSheetSize.minimum.height, idealHeight: openingSize.height, maxHeight: .infinity
            )
            .presentationSizing(.fitted)
            // Remembered only once the person finishes dragging an edge, never from layout alone: the size it opened
            // at may be the remembered one shrunk to fit this screen, which should stay remembered for a larger one.
            .background {
                ResizeEndObserver { size in
                    // Snapshots share the app's defaults, so they leave the remembered size alone.
                    if !snapshotMode { PreviewSheetSize.save(size, to: defaults) }
                }
            }
            .onGeometryChange(for: Int.self) {
                ImagePreviewStrip.length(forWidth: $0.size.width)
            } action: {
                stripLength = $0
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.space) {
                onClose()
                return .handled
            }
            .onKeyPress(.leftArrow) { show(index - 1) ? .handled : .ignored }
            .onKeyPress(.rightArrow) { show(index + 1) ? .handled : .ignored }
            .onExitCommand(perform: onClose)
            // Edit > Copy (⌘C) reaches the sheet through the responder chain when the menu handles the key first.
            .onCommand(#selector(NSText.copy(_:))) {
                if let attachment = current?.attachment { copy(attachment) }
            }
            .task { focused = true }
            .task(id: index) { await loadImage() }
            .task(id: ThumbnailRequest(strip: strip, ready: decoded != nil || failure != nil)) {
                await loadThumbnails(ready: decoded != nil || failure != nil)
            }
            .task {
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { withAnimation { showsHint = false } }
            }
            // An error sits over the image's lower edge, so it fades like the hint; a new one starts its own time.
            .task(id: actionError.shown) {
                guard actionError.text != nil else { return }
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { withAnimation { actionError.clear() } }
            }
            .onDisappear(perform: releaseAll)
    }

    // MARK: Floating controls

    /// The file and who sent it on the left, what you can do with it on the right. The name gives way first.
    private var topBar: some View {
        GlassGroup(solid: snapshotMode) {
            HStack(alignment: .top, spacing: 8) {
                CappedWidth(maxWidth: 440) { titleCapsule }
                Spacer(minLength: 0)
                if let attachment = current?.attachment { actions(attachment).fixedSize() }
            }
        }
    }

    private var titleCapsule: some View {
        HStack(spacing: 10) {
            Button(role: .close, action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
            .accessibilityLabel("Close")
            VStack(alignment: .leading, spacing: 1) {
                Text(current.map { RemoteText.title($0.attachment.contentName) } ?? "GIF")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let byline = target.byline(current?.origin ?? target.gifOrigin) {
                    Text(byline).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 16)
        .frame(minHeight: Self.topHeight)
        .modifier(FloatingBackground(cornerRadius: Self.topHeight / 2, solid: snapshotMode))
    }

    /// Icons only at every width; each one's name and shortcut are in its tooltip.
    private func actions(_ attachment: Attachment) -> some View {
        HStack(spacing: 2) {
            Button {
                copy(attachment)
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .keyboardShortcut("c")
            .help(copied ? "Copied" : "Copy (⌘C)")
            Button {
                let position = index
                Task {
                    let error = await AttachmentActions.saveAs(attachment, media: target.media)
                    if index == position { actionError.show(error) }
                }
            } label: {
                Label("Save As…", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .help("Save As… (⇧⌘S)")
            if let onShowInChat, let message = current?.origin.message {
                Button {
                    onShowInChat(message)
                } label: {
                    Label("Show in Chat", systemImage: "bubble.left")
                }
                .help("Show in Chat: close the preview and scroll to this message")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(FloatingButtonStyle())
        .padding(.horizontal, 8)
        .frame(minHeight: Self.topHeight)
        .modifier(FloatingBackground(cornerRadius: Self.topHeight / 2, solid: snapshotMode))
    }

    /// An error or the zoom hint, then the strip and the zoom controls.
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let message = actionError.text {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .modifier(FloatingBackground(cornerRadius: 14, solid: snapshotMode))
                    .transition(.opacity)
            } else if showsHint, !zoom.hasZoomed, decoded != nil {
                hint.transition(.opacity)
            }
            GlassGroup(solid: snapshotMode) {
                HStack(spacing: 8) {
                    if target.items.count > 1 { navigator }
                    if current?.attachment != nil {
                        ZoomControls(zoom: zoom, solid: snapshotMode).disabled(decoded == nil)
                    }
                }
            }
        }
    }

    // MARK: Stage

    private var stage: some View {
        ZStack {
            Self.stageColor
            content
        }
        // The controls float over the image; the gaps between them still reach it, for panning and double-clicks.
        .overlay(alignment: .top) { topBar.padding(Self.edgeInset) }
        .overlay(alignment: .bottom) { bottomBar.padding(Self.edgeInset) }
        .clipped()
    }

    @ViewBuilder
    private var content: some View {
        if let gifURL = target.gifURL {
            AnimatedGifView(url: gifURL, media: target.media, maxSide: 640)
                .padding(.horizontal, 12)
                .padding(.vertical, Self.controlsMargin)
        } else if let decoded {
            // Controls float over the top and bottom edges; a fitted image stays clear of them.
            ZoomableImage(
                image: decoded.image, controller: zoom,
                fitMargin: CGSize(width: 20, height: Self.controlsMargin),
                startMagnification: index == target.start ? startZoom : nil)
        } else if let failure {
            VStack(spacing: 12) {
                Label(mediaFailureText(failure), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                if failure.needsAnotherApp, let attachment = current?.attachment {
                    Button(opening.contains(index) ? "Opening…" : "Open") { open(attachment) }
                        .disabled(opening.contains(index))
                        .help("Open in the default app")
                }
            }
        } else {
            ProgressView()
        }
    }

    private var hint: some View {
        Text("Zoom with a pinch, ⌘-scroll, or ⌘+ and ⌘−. Double-click switches between fit and 100%.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .modifier(FloatingBackground(cornerRadius: 14, solid: snapshotMode))
    }

    // MARK: Previous and next

    private var navigator: some View {
        HStack(spacing: 6) {
            Button("Previous Image", systemImage: "chevron.left") { show(index - 1) }
                .disabled(index == 0)
                .help("Previous (←)")
            ForEach(strip, id: \.self) { thumbnail($0) }
            Text("\(index + 1) of \(target.items.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
            Button("Next Image", systemImage: "chevron.right") { show(index + 1) }
                .disabled(index >= target.items.count - 1)
                .help("Next (→)")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(FloatingButtonStyle())
        .padding(.horizontal, 7)
        .frame(minHeight: Self.bottomHeight)
        .modifier(FloatingBackground(cornerRadius: Self.bottomHeight / 2, solid: snapshotMode))
    }

    /// The strip's images: a few around the current one, so a long conversation decodes only that many.
    private var strip: Range<Int> {
        let count = target.items.count
        guard count > 1 else { return 0..<0 }
        let lower = max(0, min(index - stripLength / 2, count - stripLength))
        return lower..<min(count, lower + stripLength)
    }

    private func thumbnail(_ position: Int) -> some View {
        let selected = position == index
        let shape = RoundedRectangle(cornerRadius: 8)
        let name = RemoteText.title(target.items[position].attachment.contentName)
        return Button {
            show(position)
        } label: {
            ZStack {
                shape.fill(Color.secondary.opacity(0.15))
                if let image = thumbnails[position]?.image {
                    Image(decorative: image, scale: displayScale).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 34)
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel("Image \(position + 1): \(name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Switches to another image, releasing the current one's decode first. False when there's no such image.
    @discardableResult
    private func show(_ position: Int) -> Bool {
        guard target.items.indices.contains(position) else { return false }
        guard position != index else { return true }
        decoded?.reservation.release()
        decoded = nil
        failure = nil
        actionError.clear()
        copied = false
        index = position
        return true
    }

    // MARK: Loading

    private func loadImage() async {
        guard target.gifURL == nil, decoded == nil, let attachment = current?.attachment else { return }
        do throws(MediaLoadError) {
            let image = try await target.media.image(attachment, maxPixelSize: 3072)
            if Task.isCancelled {
                image.reservation.release()
                return
            }
            decoded = image
        } catch {
            if !Task.isCancelled { failure = error }
        }
    }

    /// For an image the preview can't show: the default app opens the exported file without decoding it here.
    private func open(_ attachment: Attachment) {
        let position = index
        guard opening.insert(position).inserted else { return }
        Task {
            let error = await AttachmentActions.open(attachment, media: target.media)
            opening.remove(position)
            // Moving to another image cleared the error line, and this result isn't about that image.
            if index == position { actionError.show(error) }
        }
    }

    private struct ThumbnailRequest: Equatable {
        let strip: Range<Int>
        let ready: Bool
    }

    /// One small decode at a time, nearest first, and only once the shown image is done so it never waits behind
    /// them. Thumbnails that leave the strip give their memory back.
    private func loadThumbnails(ready: Bool) async {
        let strip = strip
        for (position, thumbnail) in thumbnails where !strip.contains(position) {
            thumbnail.reservation.release()
            thumbnails[position] = nil
        }
        guard ready else { return }
        let center = index
        for position in strip.sorted(by: { abs($0 - center) < abs($1 - center) })
        where thumbnails[position] == nil && !failedThumbnails.contains(position) {
            do throws(MediaLoadError) {
                let image = try await target.media.image(
                    target.items[position].attachment, maxPixelSize: Self.thumbnailPixels)
                if Task.isCancelled || !self.strip.contains(position) {
                    image.reservation.release()
                    return
                }
                thumbnails[position] = image
            } catch {
                if Task.isCancelled { return }
                failedThumbnails.insert(position)
            }
        }
    }

    private func releaseAll() {
        decoded?.reservation.release()
        decoded = nil
        for thumbnail in thumbnails.values { thumbnail.reservation.release() }
        thumbnails = [:]
    }

    // MARK: Copy

    private func copy(_ attachment: Attachment) {
        let media = target.media
        let shown = decoded?.image
        let position = index
        Task {
            let written: Bool
            do throws(MediaLoadError) {
                // A copy of its own, so removing it can't take away the one Open gave another app.
                let url = try await media.export(attachment, placement: .unique)
                written = ImagePasteboard.copy(fileAt: url, contentType: attachment.contentType, shown: shown)
                // The bytes are on the pasteboard now, so the exported file isn't needed.
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            } catch {
                if index == position { actionError.show(mediaActionFailureText(error)) }
                return
            }
            // Another image is showing now; its error line and Copy button aren't about this one.
            guard index == position else { return }
            guard written else {
                actionError.show("Couldn't copy this image")
                return
            }
            actionError.clear()
            copied = true
            copies += 1
            let copy = copies
            try? await Task.sleep(for: .seconds(1.5))
            // A later copy shows its own confirmation for its full time.
            if copies == copy { copied = false }
        }
    }
}

/// Reports the content size of the window it's in each time a live resize ends: once per drag of an edge, and
/// only for a resize the person made.
private struct ResizeEndObserver: NSViewRepresentable {
    let onEnd: (CGSize) -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView(onEnd: onEnd) }

    func updateNSView(_ view: ObserverView, context: Context) { view.onEnd = onEnd }

    final class ObserverView: NSView {
        var onEnd: (CGSize) -> Void

        init(onEnd: @escaping (CGSize) -> Void) {
            self.onEnd = onEnd
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            let center = NotificationCenter.default
            center.removeObserver(self, name: NSWindow.didEndLiveResizeNotification, object: nil)
            if let newWindow {
                center.addObserver(
                    self, selector: #selector(endedLiveResize), name: NSWindow.didEndLiveResizeNotification,
                    object: newWindow)
            }
        }

        @objc private func endedLiveResize(_ notification: Notification) {
            guard let window else { return }
            onEnd(window.contentRect(forFrameRect: window.frame).size)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Zoom out, the percentage (click for actual size), zoom in, and Fit. A view of its own, so the stream of
/// magnification changes during a pinch redraws only these controls rather than the whole sheet.
private struct ZoomControls: View {
    let zoom: ZoomController
    let solid: Bool
    private static let height: CGFloat = 46

    var body: some View {
        HStack(spacing: 2) {
            Button("Zoom Out", systemImage: "minus") { zoom.zoomOut() }
                .keyboardShortcut("-")
                .disabled(!zoom.canZoomOut)
                .help("Zoom Out (⌘−)")
            Button {
                zoom.actualSize()
            } label: {
                Text(percent).monospacedDigit().frame(minWidth: 40)
            }
            .keyboardShortcut("0")
            .help("Actual Size (⌘0)")
            .accessibilityLabel("Zoom \(percent)")
            .accessibilityHint("Shows the image at actual size")
            Button("Zoom In", systemImage: "plus") { zoom.zoomIn() }
                .keyboardShortcut("+")
                .disabled(!zoom.canZoomIn)
                .help("Zoom In (⌘+)")
            Divider().frame(height: 16).padding(.horizontal, 3)
            Button("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { zoom.fit() }
                .buttonStyle(FloatingButtonStyle(selected: zoom.isFit))
                .keyboardShortcut("9")
                .help("Zoom to Fit (⌘9)")
                .accessibilityAddTraits(zoom.isFit ? .isSelected : [])
        }
        .labelStyle(.iconOnly)
        .buttonStyle(FloatingButtonStyle())
        .padding(.horizontal, 7)
        .frame(minHeight: Self.height)
        .modifier(FloatingBackground(cornerRadius: Self.height / 2, solid: solid))
        .fixedSize()
        .background {
            // ⌘= zooms in as well, so the shortcut works without Shift on keyboards where + needs it.
            Button("Zoom In") { zoom.zoomIn() }
                .keyboardShortcut("=")
                .disabled(!zoom.canZoomIn)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var percent: String { "\(Int((zoom.magnification * 100).rounded()))%" }
}

/// A borderless button for the floating controls: a soft highlight on hover and press, and a steady one when
/// `selected` (Fit while the image is fitted).
private struct FloatingButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        FloatingButton(configuration: configuration, selected: selected)
    }

    private struct FloatingButton: View {
        let configuration: Configuration
        let selected: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .frame(minWidth: 30, minHeight: 28)
                .padding(.horizontal, 2)
                .contentShape(Capsule())
                .background(Color.primary.opacity(fill), in: Capsule())
                .opacity(isEnabled ? 1 : 0.35)
                .onHover { hovering = $0 }
        }

        private var fill: Double {
            if configuration.isPressed { return 0.16 }
            if selected { return 0.1 }
            return hovering && isEnabled ? 0.07 : 0
        }
    }
}

/// Lets glass shapes that sit side by side render and blend as one group. Snapshots draw no glass, so they skip it.
private struct GlassGroup<Content: View>: View {
    let solid: Bool
    @ViewBuilder let content: Content

    var body: some View {
        if solid {
            content
        } else {
            GlassEffectContainer(spacing: 8) { content }
        }
    }
}

/// Gives its one subview the width it wants, up to `maxWidth` and the width offered, so a short title keeps a
/// short capsule and a long one stops at the cap and truncates.
private struct CappedWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let ideal = view.sizeThatFits(.unspecified).width
        let width = min(ideal, maxWidth, proposal.width ?? .infinity)
        return view.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Puts an image on the pasteboard at full quality: the original file under its own type, plus a PNG of the
/// on-screen decode when that type is one other apps might not read (HEIC, WebP and the like).
@MainActor
enum ImagePasteboard {
    private static let widelyRead: [UTType] = [.png, .tiff, .jpeg, .gif]

    static func copy(
        fileAt url: URL, contentType: String, shown: CGImage?, to pasteboard: NSPasteboard = .general
    ) -> Bool {
        // Mapped rather than read, so a large original isn't copied into this process's memory first.
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        let type = UTType(mimeType: contentType) ?? UTType(filenameExtension: url.pathExtension)
        let item = NSPasteboardItem()
        if let type, type.conforms(to: .image) {
            item.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
        }
        if !(type.map(widelyRead.contains) ?? false), let shown,
            let png = NSBitmapImageRep(cgImage: shown).representation(using: .png, properties: [:])
        {
            item.setData(png, forType: .png)
        }
        guard !item.types.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

/// Liquid Glass behind controls that float over the image. Offscreen snapshots can't draw glass, so they get a
/// solid window-coloured fill instead.
private struct FloatingBackground: ViewModifier {
    let cornerRadius: CGFloat
    let solid: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if solid {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}
