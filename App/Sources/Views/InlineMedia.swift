import AppKit
import ChatModel
import ChatNet
import ChatStore
import ChatSync
import GoogleChat
import SwiftUI

/// Plain-language text for a failed media load; never includes server text.
func mediaFailureText(_ error: MediaLoadError) -> String {
    switch error {
    case .api(let api):
        switch api {
        case .permissionDenied: "You don't have access to this file"
        case .notFound: "This file is no longer available"
        case .transport(.responseTooLarge): "This file is too large to display"
        case .transport, .rateLimited: "Couldn't download (network problem)"
        case .unauthorized, .noCredentials: "Sign-in needed"
        default: "Couldn't download this file"
        }
    case .transport(.responseTooLarge): "This file is too large to display"
    case .transport: "Couldn't download (network problem)"
    case .cache: "Couldn't read the cached file"
    case .image(let image):
        switch image {
        case .budget: "Not enough memory to show this right now"
        case .tooLarge, .tooManyFrames: "This image is too large to display"
        case .unsupported: "This image format can't be displayed"
        case .corrupt: "This image is damaged"
        case .cancelled: "Cancelled"
        }
    case .export: "Couldn't prepare the file"
    case .notUploadedContent: "Not an uploaded file"
    case .retired: "Account closed"
    }
}

/// For Open, Save As… and Copy, which download the whole file rather than display it, so a size limit there is
/// about downloading.
func mediaActionFailureText(_ error: MediaLoadError) -> String {
    switch error {
    case .transport(.responseTooLarge), .api(.transport(.responseTooLarge)): "This file is too large to download"
    default: mediaFailureText(error)
    }
}

/// Aspect ratios seen so far, so a row scrolled back into view gets a placeholder of the right shape.
@MainActor
enum ImageAspect {
    private static var known: [String: CGFloat] = [:]

    static func ratio(_ key: String) -> CGFloat? { known[key] }

    static func remember(_ key: String, _ ratio: CGFloat) {
        if known.count > 500 { known.removeAll() }
        known[key] = ratio
    }
}

enum AttachmentActions {
    /// Decrypts into the quarantined exports directory, then opens with the default app.
    @MainActor
    static func open(_ attachment: Attachment, media: MediaLoader) async -> String? {
        let url: URL
        do {
            url = try await media.export(attachment)
        } catch {
            return mediaActionFailureText(error)
        }
        guard NSWorkspace.shared.open(url) else {
            // Nothing will read the copy, so it doesn't wait for logout to be wiped.
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            return "No app on this Mac can open this file"
        }
        return nil
    }

    @MainActor
    static func saveAs(_ attachment: Attachment, media: MediaLoader) async -> String? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ExportDirectory.sanitize(attachment.contentName)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try await media.save(attachment, to: url)
            return nil
        } catch {
            return mediaActionFailureText(error)
        }
    }

    static func driveURL(_ fileID: String) -> URL? {
        guard !fileID.isEmpty,
            fileID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        else { return nil }
        return URL(string: "https://drive.google.com/open?id=\(fileID)")
    }

    @MainActor
    static func openInDrive(_ fileID: String) {
        if let url = driveURL(fileID) { NSWorkspace.shared.open(url) }
    }

    @MainActor
    static func copyDriveLink(_ fileID: String) {
        guard let url = driveURL(fileID) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

// MARK: Inline image

struct InlineImageView: View {
    let attachment: Attachment
    let media: MediaLoader
    var onOpen: () -> Void

    @Environment(\.displayScale) private var scale
    @State private var phase: Phase = .idle
    @State private var task: Task<Void, Never>?
    @State private var actionError: String?
    @State private var opening = false

    private enum Phase {
        case idle, loading
        case loaded(DecodedImage)
        case failed(MediaLoadError)
    }

    private var key: String {
        if case .uploaded(let resource) = attachment.source { return resource.rawValue }
        return attachment.contentName
    }

    private var maxPixelSize: Int { min(1024, Int(360 * scale)) }

    var body: some View {
        content
            .onAppear(perform: start)
            .onDisappear(perform: stop)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loaded(let decoded):
            let size = displaySize(decoded.image)
            Image(decorative: decoded.image, scale: scale)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: size.width, maxHeight: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
                .onTapGesture(perform: onOpen)
                .contextMenu { fileMenu }
                .help(RemoteText.title(attachment.contentName))
                .accessibilityLabel("Image \(RemoteText.title(attachment.contentName))")
                .accessibilityAddTraits(.isButton)
        case .failed(let error):
            failureCard(error)
        default:
            let ratio = ImageAspect.ratio(key) ?? 1.6
            let width: CGFloat = ratio < 1 ? 160 : 240
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10))
                ProgressView().controlSize(.small)
            }
            .aspectRatio(ratio, contentMode: .fit)
            .frame(idealWidth: width, maxWidth: width)
            .accessibilityLabel("Loading image")
        }
    }

    /// An image that can't be shown here opens in another app instead, from a click anywhere on the card. Anything
    /// else offers to load it again.
    private func failureCard(_ error: MediaLoadError) -> some View {
        let opensElsewhere = error.needsAnotherApp
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 0) {
                Text(RemoteText.title(attachment.contentName)).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(actionError ?? mediaFailureText(error)).font(.caption).foregroundStyle(.secondary)
            }
            if opensElsewhere {
                Button(opening ? "Opening…" : "Open", action: open)
                    .controlSize(.small)
                    .disabled(opening)
            } else {
                Button("Retry") {
                    actionError = nil
                    phase = .idle
                    start()
                }.controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 360, alignment: .leading)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { if opensElsewhere { open() } }
        .contextMenu { fileMenu }
        .help(opensElsewhere ? "Open in the default app" : RemoteText.title(attachment.contentName))
    }

    @ViewBuilder
    private var fileMenu: some View {
        Button("Open", action: open).disabled(opening)
        Button("Save As…") { Task { actionError = await AttachmentActions.saveAs(attachment, media: media) } }
    }

    /// Exports the file and opens it with the default app. Nothing here decodes it, so size limits don't apply.
    private func open() {
        guard !opening else { return }
        opening = true
        Task {
            actionError = await AttachmentActions.open(attachment, media: media)
            opening = false
        }
    }

    private func displaySize(_ image: CGImage) -> CGSize {
        let width = CGFloat(image.width) / scale
        let height = CGFloat(image.height) / scale
        let fit = min(1, 360 / max(width, 1), 360 / max(height, 1))
        return CGSize(width: width * fit, height: height * fit)
    }

    private func start() {
        guard task == nil else { return }
        if case .loaded = phase { return }
        phase = .loading
        BenchCounters.add { $0.imageLoads += 1 }
        let attachment = attachment
        let media = media
        let pixels = maxPixelSize
        let key = key
        task = Task {
            do {
                let decoded = try await media.image(attachment, maxPixelSize: pixels)
                if Task.isCancelled {
                    decoded.reservation.release()
                    return
                }
                ImageAspect.remember(key, CGFloat(decoded.image.width) / CGFloat(max(decoded.image.height, 1)))
                phase = .loaded(decoded)
            } catch let error as MediaLoadError {
                if !Task.isCancelled { phase = .failed(error) }
            } catch {
                phase = .idle
            }
            task = nil
        }
    }

    /// Dropping the decoded image releases its share of the memory budget.
    private func stop() {
        task?.cancel()
        task = nil
        if case .loaded(let decoded) = phase { decoded.reservation.release() }
        phase = .idle
    }
}

// MARK: Animated GIF

struct AnimatedGifView: View {
    let url: URL
    let media: MediaLoader
    var maxSide: CGFloat = 360

    @Environment(\.displayScale) private var scale
    @Environment(\.controlActiveState) private var activeState
    /// Held whole, so the frame's memory reservation lives exactly as long as it's on screen.
    @State private var frame: DecodedFrame?
    @State private var failure: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        Group {
            if let frame = frame?.image {
                let width = CGFloat(frame.width) / scale
                let height = CGFloat(frame.height) / scale
                let fit = min(1, maxSide / max(width, 1), maxSide / max(height, 1))
                Image(decorative: frame, scale: scale)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: width * fit, maxHeight: height * fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        Text("GIF").font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white).padding(5)
                    }
                    .accessibilityLabel("Animated image")
            } else if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10))
                    .aspectRatio(1.6, contentMode: .fit)
                    .frame(idealWidth: 240, maxWidth: 240)
            }
        }
        .onAppear(perform: start)
        .onDisappear {
            task?.cancel()
            task = nil
            frame = nil
        }
        .onChange(of: activeState) {
            if activeState == .inactive {
                task?.cancel()
                task = nil
            } else {
                start()
            }
        }
    }

    /// Animates only while the window is active, so a GIF in a background window costs no wake-ups.
    private func start() {
        guard task == nil, activeState != .inactive else { return }
        let url = url
        let media = media
        let pixels = min(1024, Int(maxSide * scale))
        task = Task {
            do {
                let animation = try await media.animation(at: url, maxPixelSize: pixels)
                var index = 0
                while !Task.isCancelled {
                    do throws(ImageError) {
                        frame = try await animation.frame(at: index)
                        BenchCounters.add { $0.gifFrames += 1 }
                    } catch .budget {
                        // Out of frame slots for a moment: keep the current frame and try the next tick.
                    }
                    guard animation.frameCount > 1 else { return }
                    try await Task.sleep(for: .seconds(animation.delay(at: index)))
                    index = (index + 1) % animation.frameCount
                }
            } catch let error as MediaLoadError {
                stop(mediaFailureText(error))
            } catch let error as ImageError {
                stop(mediaFailureText(.image(error)))
            } catch {
                // Cancelled while sleeping.
            }
        }
    }

    /// Playback has ended on an error: the message replaces the last frame, which also gives back its memory.
    /// A run that was cancelled (the window went inactive, or the view left) leaves what's shown alone.
    private func stop(_ message: String) {
        guard !Task.isCancelled else { return }
        frame = nil
        failure = message
    }
}
