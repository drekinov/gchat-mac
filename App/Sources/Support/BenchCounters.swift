import Foundation
import Synchronization

/// Cheap event counters printed by the benchmark, to tie CPU and memory spikes to what the app did.
enum BenchCounters {
    struct Values: Sendable {
        var snapshots = 0
        var reloads = 0
        var imageLoads = 0
        var gifFrames = 0
    }

    private static let state = Mutex(Values())

    static func add(_ update: (inout Values) -> Void) { state.withLock { update(&$0) } }
    static var values: Values { state.withLock { $0 } }
}
