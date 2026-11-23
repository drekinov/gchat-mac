import ChatModel
import Foundation

public struct FailureRule: Sendable {
    public enum Route: Sendable, Equatable {
        case any, listSpaces, getSpace, listMessages, getMessage, createMessage, listSpaceEvents, listMembers
        case updateMessage, deleteMessage
        case getSpaceReadState, updateSpaceReadState, getThreadReadState, getNotificationSetting, listCustomEmojis
        case updateThreadReadState, searchMessages
        case createReaction, deleteReaction, listReactions, uploadAttachment, downloadMedia, setUpSpace, searchDirectory
    }

    public enum Response: Sendable {
        case http(status: Int, googleStatus: String, reason: String? = nil, retryAfterSeconds: Int? = nil)
        /// 200 with a truncated body. The request is otherwise handled normally, so a write commits.
        case malformedJSON
        /// Nothing is committed.
        case networkError(URLError.Code)
        /// The write is applied, then the response is lost.
        case commitThenNetworkError(URLError.Code)
    }

    /// Nil matches any account.
    public var account: FakeAccount?
    public var route: Route
    /// Nil matches any space.
    public var space: SpaceName?
    public var onlyWithPageToken: Bool
    /// Nil never expires.
    public var times: Int?
    public var response: Response

    public init(
        account: FakeAccount? = nil, route: Route = .any, space: SpaceName? = nil, onlyWithPageToken: Bool = false,
        times: Int? = 1, response: Response
    ) {
        self.account = account
        self.route = route
        self.space = space
        self.onlyWithPageToken = onlyWithPageToken
        self.times = times
        self.response = response
    }
}

extension FailureRule {
    public static func rateLimited(
        route: Route = .any, retryAfter: Int? = nil, account: FakeAccount? = nil, space: SpaceName? = nil,
        onlyWithPageToken: Bool = false, times: Int? = 1
    ) -> FailureRule {
        FailureRule(
            account: account, route: route, space: space, onlyWithPageToken: onlyWithPageToken, times: times,
            response: .http(
                status: 429, googleStatus: "RESOURCE_EXHAUSTED", reason: "RATE_LIMIT_EXCEEDED",
                retryAfterSeconds: retryAfter))
    }

    public static func permissionDenied(
        route: Route = .any, reason: String? = nil, account: FakeAccount? = nil, space: SpaceName? = nil,
        onlyWithPageToken: Bool = false, times: Int? = 1
    ) -> FailureRule {
        FailureRule(
            account: account, route: route, space: space, onlyWithPageToken: onlyWithPageToken, times: times,
            response: .http(status: 403, googleStatus: "PERMISSION_DENIED", reason: reason))
    }

    public static func unavailable(
        route: Route = .any, account: FakeAccount? = nil, space: SpaceName? = nil, onlyWithPageToken: Bool = false,
        times: Int? = 1
    ) -> FailureRule {
        FailureRule(
            account: account, route: route, space: space, onlyWithPageToken: onlyWithPageToken, times: times,
            response: .http(status: 503, googleStatus: "UNAVAILABLE"))
    }

    public static func unauthenticated(
        route: Route = .any, account: FakeAccount? = nil, space: SpaceName? = nil, times: Int? = 1
    ) -> FailureRule {
        FailureRule(
            account: account, route: route, space: space, times: times,
            response: .http(status: 401, googleStatus: "UNAUTHENTICATED"))
    }

    public static func networkError(
        _ code: URLError.Code, route: Route = .any, account: FakeAccount? = nil, space: SpaceName? = nil,
        times: Int? = 1
    ) -> FailureRule {
        FailureRule(account: account, route: route, space: space, times: times, response: .networkError(code))
    }

    public static func lostResponse(
        _ code: URLError.Code = .networkConnectionLost, route: Route = .createMessage, account: FakeAccount? = nil,
        space: SpaceName? = nil, times: Int? = 1
    ) -> FailureRule {
        FailureRule(
            account: account, route: route, space: space, times: times, response: .commitThenNetworkError(code))
    }

    public static func malformedJSON(
        route: Route = .any, account: FakeAccount? = nil, space: SpaceName? = nil, onlyWithPageToken: Bool = false,
        times: Int? = 1
    ) -> FailureRule {
        FailureRule(
            account: account, route: route, space: space, onlyWithPageToken: onlyWithPageToken, times: times,
            response: .malformedJSON)
    }
}
