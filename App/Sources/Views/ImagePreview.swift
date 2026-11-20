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
    /// Closes the preview and scrolls the conversation to the image's message.
    var onShowInChat: ((MessageName) -> Void)?
    var onClose: () -> Void

    @Environment(\.displayScale) private var displayScale
    @Environment(\.isSnapshotMode) private var snapshotMode
    @State private var index: Int
    @State private var decoded: DecodedImage?
    @State private var failure: String?
    @State private var actionError: String?
    @State private var copied = false
    @State private var showsHint = true
    @State private var zoom = ZoomController()
    @State private var thumbnails: [Int: DecodedImage] = [:]
    @State private var failedThumbnails: Set<Int> = []
    @FocusState private var focused: Bool

    private static let stripLength = 7
    private static let thumbnailPixels = 160
    /// A little darker than the window in light mode, so a white screenshot's edges still show.
    private static let stageColor = Theme.dynamic(light: 0xE2_E5E9, dark: 0x15_171A)

    init(
        target: PreviewTarget, startZoom: CGFloat? = nil, onShowInChat: ((MessageName) -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.target = target
        self.startZoom = startZoom
        self.onShowInChat = onShowInChat
        self.onClose = onClose
        _index = State(initialValue: target.start)
    }

    private var current: PreviewTarget.Item? {
        target.items.indices.contains(index) ? target.items[index] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stage
            if let actionError {
                Text(actionError).font(.caption).foregroundStyle(Theme.error).padding(8)
            }
        }
        .frame(minWidth: 640, idealWidth: 900, minHeight: 480, idealHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
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
        .onDisappear(perform: releaseAll)
    }

    // MARK: Toolbar

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(current.map { RemoteText.title($0.attachment.contentName) } ?? "GIF")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let byline = target.byline(current?.origin ?? target.gifOrigin) {
                    Text(byline).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let attachment = current?.attachment {
                ZoomControls(zoom: zoom).disabled(decoded == nil)
                HStack(spacing: 6) {
                    Button {
                        copy(attachment)
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .keyboardShortcut("c")
                    .help("Copy (⌘C)")
                    Button {
                        Task { actionError = await AttachmentActions.saveAs(attachment, media: target.media) }
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
                        .help("Close the preview and scroll to this message")
                    }
                }
                .labelStyle(.titleAndIcon)
            }
            Button("Close", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Stage

    private var stage: some View {
        ZStack {
            Self.stageColor
            content
        }
        .overlay(alignment: .bottom) {
            if target.items.count > 1 { navigator.padding(.bottom, 14) }
        }
        .overlay(alignment: .topTrailing) {
            if showsHint, !zoom.hasZoomed, decoded != nil {
                hint.padding(12).transition(.opacity)
            }
        }
        .clipped()
    }

    @ViewBuilder
    private var content: some View {
        if let gifURL = target.gifURL {
            AnimatedGifView(url: gifURL, media: target.media, maxSide: 640).padding(12)
        } else if let decoded {
            // A strip of thumbnails floats over the bottom edge; a fitted image stays clear of it.
            ZoomableImage(
                image: decoded.image, controller: zoom,
                fitMargin: CGSize(width: 20, height: target.items.count > 1 ? 72 : 20),
                startMagnification: index == target.start ? startZoom : nil)
        } else if let failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.secondary)
        } else {
            ProgressView()
        }
    }

    private var hint: some View {
        Text("Zoom with a pinch, ⌘-scroll, or ⌘+ and ⌘−. Double-click switches between fit and 100%.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .modifier(FloatingBackground(cornerRadius: 8, solid: snapshotMode))
    }

    // MARK: Previous and next

    private var navigator: some View {
        HStack(spacing: 8) {
            Button("Previous Image", systemImage: "chevron.left") { show(index - 1) }
                .disabled(index == 0)
                .help("Previous (←)")
            ForEach(strip, id: \.self) { thumbnail($0) }
            Button("Next Image", systemImage: "chevron.right") { show(index + 1) }
                .disabled(index >= target.items.count - 1)
                .help("Next (→)")
            Text("\(index + 1) of \(target.items.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.trailing, 4)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .modifier(FloatingBackground(cornerRadius: 14, solid: snapshotMode))
    }

    /// The strip's images: a few around the current one, so a long conversation decodes only that many.
    private var strip: Range<Int> {
        let count = target.items.count
        guard count > 1 else { return 0..<0 }
        let lower = max(0, min(index - Self.stripLength / 2, count - Self.stripLength))
        return lower..<min(count, lower + Self.stripLength)
    }

    private func thumbnail(_ position: Int) -> some View {
        let selected = position == index
        let shape = RoundedRectangle(cornerRadius: 6)
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
            .frame(width: 52, height: 36)
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
        actionError = nil
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
            if !Task.isCancelled { failure = mediaFailureText(error) }
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
        Task {
            let written: Bool
            do throws(MediaLoadError) {
                let url = try await media.export(attachment)
                written = ImagePasteboard.copy(fileAt: url, contentType: attachment.contentType, shown: shown)
                // The bytes are on the pasteboard now, so the exported file isn't needed.
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            } catch {
                actionError = mediaFailureText(error)
                return
            }
            guard written else {
                actionError = "Couldn't copy this image"
                return
            }
            actionError = nil
            copied = true
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// Zoom out, the percentage (click for actual size), zoom in, and Fit. A view of its own, so the stream of
/// magnification changes during a pinch redraws only these controls rather than the whole sheet.
private struct ZoomControls: View {
    let zoom: ZoomController

    var body: some View {
        HStack(spacing: 8) {
            ControlGroup {
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
            }
            .labelStyle(.iconOnly)
            .fixedSize()
            Toggle(isOn: Binding(get: { zoom.isFit }, set: { if $0 { zoom.fit() } })) {
                Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
            }
            .toggleStyle(.button)
            .labelStyle(.titleAndIcon)
            .keyboardShortcut("9")
            .help("Zoom to Fit (⌘9)")
        }
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
