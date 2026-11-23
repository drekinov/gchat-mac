import CoreGraphics
import Foundation
import ImageIO
import Synchronization

public struct ImageLimits: Sendable, Equatable {
    public var maxPixels: Int
    public var maxBytes: Int
    public var maxFrames: Int
    public var maxDisplayPixelSize: Int

    public init(
        maxPixels: Int = 16_000_000, maxBytes: Int = 20 << 20, maxFrames: Int = 150, maxDisplayPixelSize: Int = 1024
    ) {
        self.maxPixels = maxPixels
        self.maxBytes = maxBytes
        self.maxFrames = maxFrames
        self.maxDisplayPixelSize = maxDisplayPixelSize
    }
}

public enum ImageError: Error, Sendable, Equatable {
    case tooLarge
    case tooManyFrames
    case unsupported
    case corrupt
    /// The estimated peak can never fit the memory budget, or didn't fit in time while other memory was held.
    case budget
    case cancelled
}

/// The reservation covers `image` only while it's alive, so keep both together for as long as the image is shown.
public struct DecodedImage: @unchecked Sendable {
    public let image: CGImage
    public let reservation: Reservation
}

/// Budget admitted for an encoded image before its bytes are read or downloaded. It is not copyable: passing it
/// to `thumbnail` or `animation` hands it over, and dropping it releases the budget. Pass it to
/// `SafeFetcher.fetch(_:maxBytes:admission:)` to download into it, which shrinks it to the bytes received.
public struct EncodedAdmission: ~Copyable, Sendable {
    let reservation: Reservation

    /// Bytes currently admitted.
    public var byteCount: Int { reservation.bytes }

    /// Gives back everything above `bytes`; never grows the admission.
    public func shrink(to bytes: Int) { reservation.shrink(to: bytes) }
}

/// One decoded animation frame. The reservation travels with the frame, wherever it ends up, and is handed back
/// to the animation's pool when the last reference goes away.
public final class DecodedFrame: @unchecked Sendable {
    public let image: CGImage
    public let reservation: Reservation
    private let pool: FramePool

    fileprivate init(image: CGImage, reservation: Reservation, pool: FramePool) {
        self.image = image
        self.reservation = reservation
        self.pool = pool
    }

    deinit {
        pool.give(reservation)
    }
}

private final class FramePool: Sendable {
    private let free: Mutex<[Reservation]>

    init(_ slots: [Reservation]) { free = Mutex(slots) }

    func take() -> Reservation? { free.withLock { $0.popLast() } }
    func give(_ slot: Reservation) { free.withLock { $0.append(slot) } }
}

/// Decodes untrusted image data with ImageIO under hard pixel, byte, frame and memory limits.
///
/// The decode peak is estimated as `workspace + output`:
/// - `output` is the thumbnail's `bytesPerRow * height`, with 4, 8 or 16 bytes per pixel for 8-bit, up to 16-bit
///   and wider sources, and rows rounded up to 64 bytes.
/// - `workspace` is `alpha * sourcePixels + beta * outputPixels` with per-format coefficients (see
///   `workspaceBytes`), fitted with a margin over peak `phys_footprint` measured in fresh processes for 8- and
///   16-bit PNG, JPEG, HEIC (8- and 10-bit), GIF, TIFF (8- and 16-bit) and BMP from 0.36 to 16 megapixels.
///   Formats not measured use the loosest fit, doubled for more than 8 bits per component. Float samples and more
///   than 16 bits per component are `.unsupported`.
///
/// The estimate is reserved before decoding. Afterwards the workspace and encoded bytes are returned and only the
/// real output size, taken from the decoded `CGImage`, stays held.
public final class ImagePipeline: Sendable {
    static let allowedTypes: Set<String> = [
        "public.png", "public.jpeg", "com.compuserve.gif", "public.heic", "public.heif", "org.webmproject.webp",
        "public.tiff", "com.microsoft.bmp",
    ]
    static let animationSlots = 3

    let budget: MemoryBudget
    let limits: ImageLimits
    let heldWaitTimeout: Duration

    /// `heldWaitTimeout` bounds any wait for memory made while already holding an `EncodedAdmission`.
    public init(budget: MemoryBudget, limits: ImageLimits = ImageLimits(), heldWaitTimeout: Duration = .seconds(5)) {
        self.budget = budget
        self.limits = limits
        self.heldWaitTimeout = heldWaitTimeout
    }

    /// Admits `byteCount` encoded bytes before any of them are allocated. Fails with `.tooLarge` over
    /// `limits.maxBytes` without touching the budget, and with `.budget` if the budget can never hold them.
    public func reserveEncoded(byteCount: Int) async throws(ImageError) -> EncodedAdmission {
        guard byteCount > 0 else { throw .corrupt }
        guard byteCount <= limits.maxBytes else { throw .tooLarge }
        return EncodedAdmission(reservation: try await reserve(byteCount))
    }

    /// Like `reserveEncoded(byteCount:)`, but fails with `.budget` if the memory isn't free within `timeout`.
    public func reserveEncoded(byteCount: Int, timeout: Duration) async throws(ImageError) -> EncodedAdmission {
        guard byteCount > 0 else { throw .corrupt }
        guard byteCount <= limits.maxBytes else { throw .tooLarge }
        return EncodedAdmission(reservation: try await reserve(byteCount, timeout: timeout))
    }

    /// For data that is already in memory: its size is reserved together with the decode peak.
    @concurrent
    public func thumbnail(from data: Data, maxPixelSize: Int) async throws(ImageError) -> DecodedImage {
        try await makeThumbnail(data: data, admission: nil, maxPixelSize: maxPixelSize)
    }

    /// Takes ownership of `admission` and releases it when the decode is done.
    @concurrent
    public func thumbnail(
        from data: Data, admission: consuming EncodedAdmission, maxPixelSize: Int
    ) async throws(ImageError) -> DecodedImage {
        let admitted = Admitted(byteCount: admission.byteCount, reservation: admission.reservation)
        return try await makeThumbnail(data: data, admission: admitted, maxPixelSize: maxPixelSize)
    }

    @concurrent
    public func animation(from data: Data, maxPixelSize: Int) async throws(ImageError) -> AnimatedImage {
        try await makeAnimation(data: data, admission: nil, maxPixelSize: maxPixelSize)
    }

    /// The animation keeps `admission` for its lifetime, because it keeps `data`.
    @concurrent
    public func animation(
        from data: Data, admission: consuming EncodedAdmission, maxPixelSize: Int
    ) async throws(ImageError) -> AnimatedImage {
        let admitted = Admitted(byteCount: admission.byteCount, reservation: admission.reservation)
        return try await makeAnimation(data: data, admission: admitted, maxPixelSize: maxPixelSize)
    }

    private struct Admitted {
        let byteCount: Int
        let reservation: Reservation
    }

    private func makeThumbnail(
        data: Data, admission: Admitted?, maxPixelSize: Int
    ) async throws(ImageError) -> DecodedImage {
        let (source, header) = try inspect(data, allFrames: false)
        let plan = plan(for: header.frames[0], type: header.type, maxPixelSize: maxPixelSize)
        let working: Reservation
        if let admission {
            guard data.count <= admission.byteCount else { throw .tooLarge }
            guard admission.byteCount + plan.workspace + plan.output <= budget.capacity else { throw .budget }
            working = try await reserve(plan.workspace + plan.output, timeout: heldWaitTimeout)
        } else {
            working = try await reserve(data.count + plan.workspace + plan.output)
        }
        let image = try Self.decode(source, index: 0, targetSize: plan.target)
        let actual = image.bytesPerRow * image.height
        guard actual <= plan.output else { throw .budget }
        working.shrink(to: actual)
        return DecodedImage(image: image, reservation: working)
    }

    private func makeAnimation(
        data: Data, admission: Admitted?, maxPixelSize: Int
    ) async throws(ImageError) -> AnimatedImage {
        let (source, header) = try inspect(data, allFrames: true)
        let plans = header.frames.map { plan(for: $0, type: header.type, maxPixelSize: maxPixelSize) }
        let workspace = plans.map(\.workspace).max() ?? 0
        let slotBytes = plans.map(\.output).max() ?? 0
        let extra = workspace + Self.animationSlots * slotBytes
        var holds: [Reservation] = []
        let base: Reservation
        if let admission {
            guard data.count <= admission.byteCount else { throw .tooLarge }
            guard admission.byteCount + extra <= budget.capacity else { throw .budget }
            holds.append(admission.reservation)
            base = try await reserve(extra, timeout: heldWaitTimeout)
        } else {
            base = try await reserve(data.count + extra)
        }
        holds.append(base)
        var slots: [Reservation] = []
        for _ in 0..<Self.animationSlots {
            guard let slot = base.split(slotBytes) else { throw .budget }
            slots.append(slot)
        }
        return AnimatedImage(source: source, plans: plans, pool: FramePool(slots), holds: holds)
    }

    func reserve(_ bytes: Int, timeout: Duration? = nil) async throws(ImageError) -> Reservation {
        do {
            if let timeout { return try await budget.reserve(bytes, timeout: timeout) }
            return try await budget.reserve(bytes)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .budget
        }
    }

    struct FrameInfo {
        var width: Int
        var height: Int
        var depth: Int
        var orientation = 1
        var isFloat = false

        /// Dimensions after the EXIF/TIFF orientation transform, which is what the thumbnail is laid out in.
        var displayWidth: Int { (5...8).contains(orientation) ? height : width }
        var displayHeight: Int { (5...8).contains(orientation) ? width : height }
    }

    struct Header {
        var type: String
        var frames: [FrameInfo]
    }

    struct Plan {
        var target: Int
        var output: Int
        var workspace: Int
    }

    /// Validates the encoded data without decoding: type, structure, frame count, and the dimensions of the first
    /// frame (or of every frame, for animations).
    func inspect(_ data: Data, allFrames: Bool) throws(ImageError) -> (SourceBox, Header) {
        guard !data.isEmpty else { throw .corrupt }
        guard data.count <= limits.maxBytes else { throw .tooLarge }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
            let type = CGImageSourceGetType(source) as String?
        else { throw .unsupported }
        guard Self.allowedTypes.contains(type) else { throw .unsupported }
        let count = CGImageSourceGetCount(source)
        guard count <= limits.maxFrames else { throw .tooManyFrames }
        guard count > 0, let first = Self.frameInfo(source, 0, options) else {
            if type == "public.png", let (width, height) = Self.pngHeaderSize(data), exceeds(width, height) {
                throw .tooLarge
            }
            throw .corrupt
        }
        guard !exceeds(first.width, first.height) else { throw .tooLarge }
        guard Self.isSupportedDepth(first) else { throw .unsupported }
        guard ImageStructure.isComplete(data, type: type) else { throw .corrupt }
        var frames = [first]
        if allFrames {
            for index in 1..<max(count, 1) {
                guard let info = Self.frameInfo(source, index, options) else { throw .corrupt }
                guard !exceeds(info.width, info.height) else { throw .tooLarge }
                guard Self.isSupportedDepth(info) else { throw .unsupported }
                frames.append(info)
            }
        }
        return (SourceBox(source), Header(type: type, frames: frames))
    }

    /// Float samples and more than 16 bits per component decode to buffers far larger than any estimate here.
    private static func isSupportedDepth(_ frame: FrameInfo) -> Bool {
        !frame.isFloat && frame.depth <= 16
    }

    private static func frameInfo(_ source: CGImageSource, _ index: Int, _ options: CFDictionary) -> FrameInfo? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, options) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return nil }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let orientation =
            (properties[kCGImagePropertyOrientation] as? Int) ?? (tiff?[kCGImagePropertyTIFFOrientation] as? Int) ?? 1
        return FrameInfo(
            width: width, height: height, depth: properties[kCGImagePropertyDepth] as? Int ?? 8,
            orientation: (1...8).contains(orientation) ? orientation : 1,
            isFloat: properties[kCGImagePropertyIsFloat] as? Bool ?? false)
    }

    private func exceeds(_ width: Int, _ height: Int) -> Bool {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow || pixels > limits.maxPixels
    }

    /// The IHDR dimensions of a PNG, used when ImageIO can't read a header-only file.
    static func pngHeaderSize(_ data: Data) -> (Int, Int)? {
        guard data.count >= 24 else { return nil }
        let bytes = [UInt8](data.prefix(24))
        func word(_ offset: Int) -> Int { bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) } }
        guard bytes[12..<16].elementsEqual("IHDR".utf8) else { return nil }
        return (word(16), word(20))
    }

    /// Bytes per pixel of the decoded thumbnail.
    static func outputBytesPerPixel(depth: Int) -> Int {
        depth > 16 ? 16 : depth > 8 ? 8 : 4
    }

    /// `alpha * sourcePixels + beta * outputPixels`, in bytes.
    static func workspaceBytes(type: String, depth: Int, sourcePixels: Int, outputPixels: Int) -> Int {
        let (alpha, beta): (Double, Double)
        switch type {
        case "public.jpeg": (alpha, beta) = (1.4, 22)
        case "public.png": (alpha, beta) = depth > 8 ? (1.5, 44) : (0.75, 23)
        case "com.compuserve.gif": (alpha, beta) = (5.7, 5.6)
        case "public.heic", "public.heif": (alpha, beta) = depth > 8 ? (5, 140) : (0.5, 14)
        default: (alpha, beta) = (9.5, 7.2)
        }
        let ownsDepthFit = ["public.png", "public.heic", "public.heif"].contains(type)
        let depthFactor: Double = depth > 8 && !ownsDepthFit ? 2 : 1
        return Int((depthFactor * (alpha * Double(sourcePixels) + beta * Double(outputPixels))).rounded(.up))
    }

    func plan(for frame: FrameInfo, type: String, maxPixelSize: Int) -> Plan {
        let width = frame.displayWidth
        let height = frame.displayHeight
        let longest = max(width, height)
        let target = max(1, min(maxPixelSize, limits.maxDisplayPixelSize, longest))
        let outWidth = max(1, (width * target + longest - 1) / longest)
        let outHeight = max(1, (height * target + longest - 1) / longest)
        let rowBytes = (outWidth * Self.outputBytesPerPixel(depth: frame.depth) + 63) / 64 * 64
        return Plan(
            target: target, output: rowBytes * outHeight,
            workspace: Self.workspaceBytes(
                type: type, depth: frame.depth, sourcePixels: frame.width * frame.height,
                outputPixels: outWidth * outHeight))
    }

    static func decode(_ source: SourceBox, index: Int, targetSize: Int) throws(ImageError) -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: targetSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = source.withSource({ CGImageSourceCreateThumbnailAtIndex($0, index, options as CFDictionary) })
        else { throw .corrupt }
        guard source.withSource({ CGImageSourceGetStatusAtIndex($0, index) }) == .statusComplete else { throw .corrupt }
        return image
    }
}

/// Serializes use of one `CGImageSource`, which isn't documented as safe for concurrent use.
final class SourceBox: @unchecked Sendable {
    private let source: CGImageSource
    private let lock = Mutex(())

    init(_ source: CGImageSource) { self.source = source }

    func withSource<T>(_ body: (CGImageSource) -> T) -> T {
        lock.withLock { _ in body(source) }
    }
}

/// An animated image whose frames decode on demand at a fixed pixel size.
///
/// Everything it can ever need is reserved when it is created: the encoded bytes, one decoder workspace (decodes
/// run one at a time), and three frame slots, so playback never waits for memory. The cache keeps two frames; a
/// third slot covers the frame a caller is still holding. A frame keeps its slot until it is released, so frames
/// that outlive the cache stay accounted. `frame(at:)` fails with `.budget` only if the caller holds all three.
public final class AnimatedImage: Sendable {
    public let frameCount: Int

    private let source: SourceBox
    private let plans: [ImagePipeline.Plan]
    private let pool: FramePool
    private let holds: [Reservation]
    private let cache = Mutex<[(index: Int, frame: DecodedFrame)]>([])

    var cachedFrameCount: Int { cache.withLock { $0.count } }

    fileprivate init(source: SourceBox, plans: [ImagePipeline.Plan], pool: FramePool, holds: [Reservation]) {
        self.source = source
        self.plans = plans
        self.frameCount = plans.count
        self.pool = pool
        self.holds = holds
    }

    /// Seconds to show frame `index`, with the usual 0.1 s floor for GIF delays that are 0 or missing.
    public func delay(at index: Int) -> TimeInterval {
        guard index >= 0, index < frameCount else { return 0.1 }
        let delay = source.withSource { source -> Double? in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
        }
        guard let delay, delay >= 0.02 else { return 0.1 }
        return delay
    }

    @concurrent
    public func frame(at index: Int) async throws(ImageError) -> DecodedFrame {
        guard index >= 0, index < frameCount else { throw .corrupt }
        if let cached = cache.withLock({ $0.first { $0.index == index }?.frame }) { return cached }
        var dropped = cache.withLock { frames -> [DecodedFrame] in
            var removed: [DecodedFrame] = []
            while frames.count > 1 { removed.append(frames.removeFirst().frame) }
            return removed
        }
        dropped.removeAll()
        guard let slot = pool.take() else { throw .budget }
        let image: CGImage
        do {
            image = try ImagePipeline.decode(source, index: index, targetSize: plans[index].target)
        } catch {
            pool.give(slot)
            throw error
        }
        guard image.bytesPerRow * image.height <= slot.bytes else {
            pool.give(slot)
            throw .budget
        }
        let frame = DecodedFrame(image: image, reservation: slot, pool: pool)
        cache.withLock { frames in
            frames.removeAll { $0.index == index }
            frames.append((index, frame))
        }
        return frame
    }
}
