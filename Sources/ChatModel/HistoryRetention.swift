import Foundation

/// Created times `[from, until)` during which a space had history off; nil bounds are open.
public struct HistoryOffWindow: Hashable, Sendable, Codable {
    public var from: Timestamp?
    public var until: Timestamp?

    enum CodingKeys: String, CodingKey {
        case from = "f"
        case until = "u"
    }

    public init(from: Timestamp? = nil, until: Timestamp? = nil) {
        self.from = from
        self.until = until
    }

    public func contains(_ time: Timestamp) -> Bool {
        (from.map { $0 <= time } ?? true) && (until.map { time < $0 } ?? true)
    }
}

/// Google deletes messages sent while a space's history is off about 24 hours after they were sent, without telling
/// clients; the API keeps no per-message history state. This is the local record of when a space had history off,
/// stored under `historyOff|<space>`, and the rule the cache and the UI drop such messages by.
public struct HistoryRetention: Hashable, Sendable, Codable {
    public static let keyPrefix = "historyOff|"
    public static let lifetime = Duration.seconds(24 * 3600)
    /// A listing sees a switch to history off up to a poll interval late, so the window opens this much earlier.
    public static let observationMargin = Duration.seconds(300)
    /// A closed window is forgotten this long after its last message expired.
    static let keptAfterExpiry = Duration.seconds(2 * 24 * 3600)
    static let maxWindows = 16

    public var windows: [HistoryOffWindow]
    /// When the oldest cached message inside a window expires; nil when none is cached.
    public var due: Timestamp?

    enum CodingKeys: String, CodingKey {
        case windows = "w"
        case due = "d"
    }

    public init(windows: [HistoryOffWindow] = [], due: Timestamp? = nil) {
        self.windows = windows
        self.due = due
    }

    public static func key(_ space: SpaceName) -> String { keyPrefix + space.rawValue }

    public var hasOpenWindow: Bool { windows.contains { $0.until == nil } }

    /// The windows in force for a space whose current state is `historyOn`: one seen off with no window recorded has
    /// been off for as long as anything here knows.
    public func effective(historyOn: Bool?) -> HistoryRetention {
        guard historyOn == false, !hasOpenWindow else { return self }
        var copy = self
        copy.windows.append(HistoryOffWindow(from: nil, until: nil))
        return copy
    }

    public static func cutoff(at now: Timestamp) -> Timestamp { now.adding(.zero - lifetime) }

    public func isExpired(_ createTime: Timestamp, now: Timestamp) -> Bool {
        createTime < Self.cutoff(at: now) && windows.contains { $0.contains(createTime) }
    }

    /// Records the state `historyOn` seen at `at`, after `previous`. True when the windows changed.
    @discardableResult
    public mutating func observe(historyOn: Bool, previous: Bool?, at: Timestamp, margin: Duration) -> Bool {
        if historyOn {
            if let open = windows.firstIndex(where: { $0.until == nil }) {
                windows[open].until = max(at, windows[open].from ?? at)
                return true
            }
            guard previous == false else { return false }
            windows.append(HistoryOffWindow(from: nil, until: at))
        } else {
            guard !hasOpenWindow else { return false }
            windows.append(HistoryOffWindow(from: previous == true ? at.adding(.zero - margin) : nil, until: nil))
        }
        compact()
        return true
    }

    /// Moves the edge a listing guessed for the current state to `at`, when Google's own time for that change is known:
    /// an open window starts there, the latest closed one ends there.
    @discardableResult
    public mutating func refine(historyOn: Bool, at: Timestamp) -> Bool {
        if historyOn {
            guard !hasOpenWindow, let last = windows.indices.last, let until = windows[last].until, at < until else {
                return false
            }
            windows[last].until = max(at, windows[last].from ?? at)
        } else {
            guard let open = windows.firstIndex(where: { $0.until == nil }), let from = windows[open].from, at < from
            else { return false }
            windows[open].from = at
        }
        return true
    }

    /// Drops closed windows whose messages are long expired, and merges the oldest when there are too many.
    public mutating func forgetExpired(now: Timestamp) {
        windows.removeAll { window in
            guard let until = window.until else { return false }
            return until.adding(Self.lifetime + Self.keptAfterExpiry) < now
        }
        compact()
    }

    private mutating func compact() {
        var seen: Set<HistoryOffWindow> = []
        windows = windows.filter { seen.insert($0).inserted }
        windows.sort { ($0.from ?? Timestamp(seconds: .min)) < ($1.from ?? Timestamp(seconds: .min)) }
        while windows.count > Self.maxWindows {
            let first = windows.removeFirst()
            windows[0].from = first.from
        }
    }
}
