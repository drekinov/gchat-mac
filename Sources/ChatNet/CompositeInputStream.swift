import Foundation
import Synchronization

/// Reads `prefix`, then exactly the identified file's bytes, then `suffix`, at most 64 KiB per `read`.
/// File bytes come from one shared descriptor via `pread`, so any number of streams (retries) can read it
/// independently. The file is checked against `identity` before each read, after each read and before any bytes
/// are returned, and when the stream ends; any mismatch, or an early end, fails the stream and reports a violation.
final class CompositeInputStream: InputStream, @unchecked Sendable {
    static let readSize = 64 * 1024

    private struct State {
        var segment = 0
        var offset = 0
        var status: Stream.Status = .notOpen
        var error: (any Error)?
    }

    private enum Segment {
        case bytes(Data)
        case file(length: Int)

        var length: Int {
            switch self {
            case .bytes(let data): data.count
            case .file(let length): length
            }
        }
    }

    private let segments: [Segment]
    private let file: OpenedFile
    private let identity: FileIdentity
    private let onViolation: @Sendable () -> Void
    private let afterRead: (@Sendable () -> Void)?
    private let state = Mutex(State())
    // Set by the stream's single consumer before it starts reading.
    nonisolated(unsafe) private weak var streamDelegate: (any StreamDelegate)?
    nonisolated(unsafe) private var clientCallback: CFReadStreamClientCallBack?
    nonisolated(unsafe) private var clientContext = CFStreamClientContext()

    init(
        prefix: Data, file: OpenedFile, identity: FileIdentity, suffix: Data,
        onViolation: @escaping @Sendable () -> Void = {}, afterRead: (@Sendable () -> Void)? = nil
    ) {
        var parts: [Segment] = []
        if !prefix.isEmpty { parts.append(.bytes(prefix)) }
        if identity.size > 0 { parts.append(.file(length: Int(identity.size))) }
        if !suffix.isEmpty { parts.append(.bytes(suffix)) }
        segments = parts
        self.file = file
        self.identity = identity
        self.onViolation = onViolation
        self.afterRead = afterRead
        super.init(data: Data())
    }

    var totalLength: Int { segments.reduce(0) { $0 + $1.length } }

    override var streamStatus: Stream.Status { state.withLock { $0.status } }
    override var streamError: (any Error)? { state.withLock { $0.error } }
    override var delegate: (any StreamDelegate)? {
        get { streamDelegate }
        set { streamDelegate = newValue }
    }

    override var hasBytesAvailable: Bool {
        state.withLock { $0.status != .atEnd && $0.status != .closed && $0.status != .error }
    }

    override func open() {
        state.withLock {
            if $0.status == .notOpen { $0.status = segments.isEmpty ? .atEnd : .open }
        }
    }

    override func close() {
        state.withLock { $0.status = .closed }
    }

    override func property(forKey key: Stream.PropertyKey) -> Any? { nil }
    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool { false }
    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length: UnsafeMutablePointer<Int>
    ) -> Bool { false }

    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        let (count, violated) = state.withLock { state -> (Int, Bool) in
            if state.status == .notOpen { state.status = .open }
            guard state.status == .open else { return (state.status == .atEnd ? 0 : -1, false) }
            guard len > 0 else { return (0, false) }
            guard state.segment < segments.count else {
                state.status = .atEnd
                return (0, false)
            }
            let segment = segments[state.segment]
            let want = min(len, Self.readSize, segment.length - state.offset)
            let produced: Int
            switch segment {
            case .bytes(let data):
                let start = data.startIndex + state.offset
                data.copyBytes(to: buffer, from: start..<(start + want))
                produced = want
            case .file:
                guard file.currentIdentity() == identity else { return fail(&state) }
                var count = pread(file.descriptor, buffer, want, off_t(state.offset))
                while count < 0, errno == EINTR { count = pread(file.descriptor, buffer, want, off_t(state.offset)) }
                afterRead?()
                guard count > 0, file.currentIdentity() == identity else { return fail(&state) }
                produced = count
            }
            state.offset += produced
            if state.offset >= segment.length {
                state.segment += 1
                state.offset = 0
                if state.segment >= segments.count {
                    guard file.currentIdentity() == identity else { return fail(&state) }
                    state.status = .atEnd
                }
            }
            return (produced, false)
        }
        if violated { onViolation() }
        return count
    }

    private func fail(_ state: inout State) -> (Int, Bool) {
        state.error = CocoaError(.fileReadUnknown)
        state.status = .error
        return (-1, true)
    }

    // CFNetwork bridges to these private selectors rather than the public run-loop methods.
    @objc(_scheduleInCFRunLoop:forMode:)
    func scheduleInCFRunLoop(_ runLoop: CFRunLoop, forMode mode: CFRunLoopMode) {}

    @objc(_unscheduleFromCFRunLoop:forMode:)
    func unscheduleFromCFRunLoop(_ runLoop: CFRunLoop, forMode mode: CFRunLoopMode) {}

    @objc(_setCFClientFlags:callback:context:)
    func setCFClientFlags(
        _ flags: CFOptionFlags, callback: CFReadStreamClientCallBack?,
        context: UnsafeMutablePointer<CFStreamClientContext>?
    ) -> Bool {
        clientCallback = callback
        if let context { clientContext = context.pointee }
        return true
    }
}
