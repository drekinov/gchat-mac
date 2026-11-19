import AppKit
import ChatSync
import Network

/// One path monitor for the whole app plus system wake, delivered to the accounts in the order they happened.
@MainActor
final class ConnectivityMonitor {
    private enum Event: Sendable {
        case path(Connectivity)
        case wake
    }

    private let monitor = NWPathMonitor()
    private let continuation: AsyncStream<Event>.Continuation
    private let consumer: Task<Void, Never>
    private var wakeObserver: (any NSObjectProtocol)?

    init(manager: AccountManager) {
        let (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        consumer = Task {
            for await event in events {
                switch event {
                case .path(let connectivity): await manager.setConnectivity(connectivity)
                case .wake: await manager.systemDidWake()
                }
            }
        }
        monitor.pathUpdateHandler = { @Sendable path in
            continuation.yield(.path(path.status == .satisfied ? .reachable : .unreachable))
        }
        monitor.start(queue: DispatchQueue(label: "connectivity", qos: .utility))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { @Sendable _ in continuation.yield(.wake) }
    }

    func stop() {
        monitor.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        continuation.finish()
        consumer.cancel()
    }
}
