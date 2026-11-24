import Foundation

/// Runs a cleanup off the caller's actor, one at a time. A request that arrives while it runs makes it run once more
/// afterwards, however many arrive, so a burst of requests costs at most two runs.
public actor ExportSweeper {
    private let sweep: @Sendable () -> Void
    private var running = false
    private var again = false

    public init(_ sweep: @escaping @Sendable () -> Void) {
        self.sweep = sweep
    }

    /// Runs the cleanup now, or once more after the run in progress.
    public func request() async {
        guard !running else {
            again = true
            return
        }
        running = true
        repeat {
            again = false
            await Self.run(sweep)
        } while again
        running = false
    }

    /// Runs the cleanup every `interval` until the task is cancelled. The wait counts time the Mac spends asleep,
    /// so the first run after waking comes promptly.
    public func repeating(every interval: Duration) async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: interval) } catch { return }
            await request()
        }
    }

    @concurrent
    private static func run(_ sweep: @Sendable () -> Void) async {
        sweep()
    }
}
