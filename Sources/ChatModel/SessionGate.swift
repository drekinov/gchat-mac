import Synchronization

public struct Generation: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let value: UInt64

    public init(_ value: UInt64) { self.value = value }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
    public var description: String { "g\(value)" }
}

public enum SessionState: Sendable, Equatable {
    case active
    case closing
    case closed
}

public struct GateClosed: Error, Sendable, Equatable {
    public init() {}
}

/// The per-account commit boundary. A persistent write runs inside `commit`, which holds the gate's lock across the
/// generation check and the write, so once `retire()` returns no writer of an older generation can commit.
public final class SessionGate: Sendable {
    private struct State {
        var generation: Generation
        var state: SessionState

        mutating func retire() -> Generation {
            generation = Generation(generation.value + 1)
            state = .closing
            return generation
        }
    }

    private let state: Mutex<State>

    public init(generation: Generation = Generation(1), state: SessionState = .active) {
        self.state = Mutex(State(generation: generation, state: state))
    }

    /// The generation work should be tagged with, or `nil` when the session isn't active.
    public var current: Generation? {
        state.withLock { $0.state == .active ? $0.generation : nil }
    }

    public var snapshot: (Generation, SessionState) {
        state.withLock { ($0.generation, $0.state) }
    }

    public func isCurrent(_ generation: Generation) -> Bool {
        state.withLock { $0.state == .active && $0.generation == generation }
    }

    /// Runs `body` only if `generation` is current and active. `body` must be synchronous and must not touch the gate.
    public func commit<T, E: Error>(_ generation: Generation, _ body: () throws(E) -> T) throws -> T {
        try state.withLock { state throws -> T in
            guard state.state == .active, state.generation == generation else { throw GateClosed() }
            return try body()
        }
    }

    /// Retires the current generation and enters `closing`. Waits for an in-flight commit to finish.
    @discardableResult
    public func retire() -> Generation {
        state.withLock { $0.retire() }
    }

    /// Replaces credentials while writers are excluded. A failed replacement leaves the session active.
    @discardableResult
    public func retire(after prepare: () throws -> Void) throws -> Generation {
        try state.withLock { state in
            guard state.state == .active else { throw GateClosed() }
            try prepare()
            return state.retire()
        }
    }

    public func close() {
        state.withLock { $0.state = .closed }
    }

    /// A new generation after re-login; anything tagged with an older one stays rejected.
    public func activate() -> Generation {
        state.withLock { state in
            state.generation = Generation(state.generation.value + 1)
            state.state = .active
            return state.generation
        }
    }
}
