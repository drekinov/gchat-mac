import Foundation

/// What a failed call is allowed to conclude about a space. Only reconciliation hides spaces.
public enum SpaceErrorImpact: Sendable, Equatable {
    /// Transient or account-level; the space is untouched.
    case none
    /// This feature is unavailable for the space (announcement-only, preview API, admin policy); keep the space.
    case featureUnavailable
    /// Membership may be lost. Hide the space only if `spaces.list` confirms it's gone.
    case suspectMembershipLoss
}

public enum ChatOperation: Sendable, Equatable {
    case listSpaces
    case readSpace
    case listMessages
    case listSpaceEvents
    case listMemberships
    case getSpaceReadState
    case updateSpaceReadState
    case getThreadReadState
    case updateThreadReadState
    case searchMessages
    case getNotificationSetting
    case listCustomEmojis
    case createMessage
    case updateMessage
    case deleteMessage
    case setUpDirectMessage
    case searchDirectory
    case createReaction
    case deleteReaction
    case listReactions
    case uploadAttachment
    case downloadMedia

    var isCoreRead: Bool {
        switch self {
        case .readSpace, .listMessages, .listSpaceEvents, .listMemberships: true
        default: false
        }
    }
}

extension ChatAPIError {
    public func spaceImpact(of operation: ChatOperation) -> SpaceErrorImpact {
        switch self {
        case .notFound where operation.isCoreRead, .permissionDenied where operation.isCoreRead:
            .suspectMembershipLoss
        case .permissionDenied, .notFound, .failedPrecondition:
            .featureUnavailable
        default:
            .none
        }
    }
}

/// Truncated exponential backoff: `min(2^attempt s + jitter, cap)`, jitter in `0..<1 s`.
public struct Backoff: Sendable, Equatable {
    public var cap: Duration

    public init(cap: Duration = .seconds(64)) { self.cap = cap }

    public func delay(attempt: Int, jitter: Double = Double.random(in: 0..<1)) -> Duration {
        let base = Duration.seconds(1 << min(max(attempt, 0), 16))
        return min(base + .milliseconds(Int(max(0, min(jitter, 0.999)) * 1000)), cap)
    }

    /// A server-provided `Retry-After` wins when it's longer.
    public func delay(attempt: Int, after error: ChatAPIError, jitter: Double = Double.random(in: 0..<1)) -> Duration {
        let computed = delay(attempt: attempt, jitter: jitter)
        if case .rateLimited(let retryAfter?) = error { return max(computed, retryAfter) }
        return computed
    }
}
