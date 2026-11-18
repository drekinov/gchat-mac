import ChatModel

enum Endpoint {
    case listSpaces
    case getSpace(SpaceName)
    case listMessages(SpaceName)
    case createMessage(SpaceName)
    case getMessage(MessageName)
    case listSpaceEvents(SpaceName)
    case listMembers(SpaceName)
    case getSpaceReadState(SpaceName, user: String)
    case updateSpaceReadState(SpaceName, user: String)
    case getThreadReadState(SpaceName, ThreadName, user: String)
    case updateThreadReadState(SpaceName, ThreadName, user: String)
    case searchMessages
    case getNotificationSetting(SpaceName, user: String)
    case listCustomEmojis
    case createReaction(MessageName)
    case deleteReaction(ReactionName)
    case listReactions(MessageName)
    case uploadAttachment(SpaceName)
    case downloadMedia(MediaResourceName)
    case setUpSpace
    case searchDirectory

    var route: FailureRule.Route {
        switch self {
        case .listSpaces: .listSpaces
        case .getSpace: .getSpace
        case .listMessages: .listMessages
        case .createMessage: .createMessage
        case .getMessage: .getMessage
        case .listSpaceEvents: .listSpaceEvents
        case .listMembers: .listMembers
        case .getSpaceReadState: .getSpaceReadState
        case .updateSpaceReadState: .updateSpaceReadState
        case .getThreadReadState: .getThreadReadState
        case .updateThreadReadState: .updateThreadReadState
        case .searchMessages: .searchMessages
        case .getNotificationSetting: .getNotificationSetting
        case .listCustomEmojis: .listCustomEmojis
        case .createReaction: .createReaction
        case .deleteReaction: .deleteReaction
        case .listReactions: .listReactions
        case .uploadAttachment: .uploadAttachment
        case .downloadMedia: .downloadMedia
        case .setUpSpace: .setUpSpace
        case .searchDirectory: .searchDirectory
        }
    }

    var space: SpaceName? {
        switch self {
        case .listSpaces, .listCustomEmojis, .downloadMedia, .setUpSpace, .searchDirectory, .searchMessages: nil
        case .getSpace(let space), .listMessages(let space), .createMessage(let space), .listSpaceEvents(let space),
            .listMembers(let space), .getSpaceReadState(let space, _), .updateSpaceReadState(let space, _),
            .getThreadReadState(let space, _, _), .updateThreadReadState(let space, _, _),
            .getNotificationSetting(let space, _), .uploadAttachment(let space):
            space
        case .getMessage(let message), .createReaction(let message), .listReactions(let message): message.space
        case .deleteReaction(let reaction): reaction.message.space
        }
    }

    static let directoryHost = "people.googleapis.com"

    static func parse(method: String, path: String, host: String = "chat.googleapis.com") -> Endpoint? {
        var parts = path.split(separator: "/").map(String.init)
        let isUpload = parts.first == "upload"
        if isUpload { parts.removeFirst() }
        guard parts.first == "v1" else { return nil }
        let rest = Array(parts.dropFirst())
        let isGet = method == "GET"

        func space(_ id: String) -> SpaceName? { SpaceName("spaces/\(id)") }

        if host == directoryHost {
            return !isUpload && isGet && rest == ["people:searchDirectoryPeople"] ? .searchDirectory : nil
        }
        if isUpload {
            guard method == "POST", rest.count == 3, rest[0] == "spaces", rest[2] == "attachments:upload",
                let name = space(rest[1])
            else { return nil }
            return .uploadAttachment(name)
        }
        if rest == ["spaces:setup"] { return method == "POST" ? .setUpSpace : nil }
        if rest == ["spaces", "-", "messages:search"] { return method == "POST" ? .searchMessages : nil }
        if rest.count >= 2, rest[0] == "media" {
            guard isGet else { return nil }
            return MediaResourceName(rest.dropFirst().joined(separator: "/")).map { .downloadMedia($0) }
        }

        switch rest.count {
        case 1 where rest[0] == "spaces" && isGet:
            return .listSpaces
        case 1 where rest[0] == "customEmojis" && isGet:
            return .listCustomEmojis
        case 2 where rest[0] == "spaces" && isGet:
            return space(rest[1]).map { .getSpace($0) }
        case 3 where rest[0] == "spaces":
            guard let name = space(rest[1]) else { return nil }
            switch (rest[2], method) {
            case ("messages", "GET"): return .listMessages(name)
            case ("messages", "POST"): return .createMessage(name)
            case ("spaceEvents", "GET"): return .listSpaceEvents(name)
            case ("members", "GET"): return .listMembers(name)
            default: return nil
            }
        case 4 where rest[0] == "spaces" && rest[2] == "messages" && isGet:
            return MessageName("spaces/\(rest[1])/messages/\(rest[3])").map { .getMessage($0) }
        case 5 where rest[0] == "spaces" && rest[2] == "messages" && rest[4] == "reactions":
            guard let message = MessageName("spaces/\(rest[1])/messages/\(rest[3])") else { return nil }
            switch method {
            case "POST": return .createReaction(message)
            case "GET": return .listReactions(message)
            default: return nil
            }
        case 6 where rest[0] == "spaces" && rest[2] == "messages" && rest[4] == "reactions" && method == "DELETE":
            return ReactionName("spaces/\(rest[1])/messages/\(rest[3])/reactions/\(rest[5])").map {
                .deleteReaction($0)
            }
        case 5 where rest[0] == "users" && rest[2] == "spaces":
            guard let name = space(rest[3]) else { return nil }
            switch (rest[4], method) {
            case ("spaceReadState", "GET"): return .getSpaceReadState(name, user: rest[1])
            case ("spaceReadState", "PATCH"): return .updateSpaceReadState(name, user: rest[1])
            case ("spaceNotificationSetting", "GET"): return .getNotificationSetting(name, user: rest[1])
            default: return nil
            }
        case 7
        where rest[0] == "users" && rest[2] == "spaces" && rest[4] == "threads" && rest[6] == "threadReadState"
            && (isGet || method == "PATCH"):
            guard let thread = ThreadName("spaces/\(rest[3])/threads/\(rest[5])") else { return nil }
            return isGet
                ? .getThreadReadState(thread.space, thread, user: rest[1])
                : .updateThreadReadState(thread.space, thread, user: rest[1])
        default:
            return nil
        }
    }
}
