import ChatModel
import Foundation

extension State {
    static let derivedEmailDomain = "fake.example"

    func email(for user: User) -> String {
        if let email = emails[user.name] { return email }
        let words = (user.displayName ?? "").lowercased().split { !($0.isLetter || $0.isNumber) }
        let local = words.isEmpty ? "user\(user.name.id(at: 0))" : words.joined(separator: ".")
        return "\(local)@\(Self.derivedEmailDomain)"
    }

    private func resolveUser(_ id: String) -> User? {
        if id.contains("@") {
            let wanted = id.lowercased()
            return knownUsers.values.sorted { $0.name < $1.name }.first { email(for: $0).lowercased() == wanted }
        }
        return UserName("users/\(id)").flatMap { knownUsers[$0] }
    }

    mutating func setUpSpace(_ incoming: IncomingRequest, _ account: FakeAccount) throws(WireError) -> Reply {
        guard let data = incoming.body, let body = (try? JSONSerialization.jsonObject(with: data)) as? JSON else {
            throw .invalidArgument("Request body must be a JSON object")
        }
        guard (body["space"] as? JSON)?["spaceType"] as? String == "DIRECT_MESSAGE" else {
            throw .invalidArgument("space.spaceType must be DIRECT_MESSAGE")
        }
        let memberships = body["memberships"] as? [JSON] ?? []
        guard memberships.count == 1, let member = memberships[0]["member"] as? JSON,
            let rawName = member["name"] as? String, rawName.hasPrefix("users/"), rawName.count > "users/".count
        else { throw .invalidArgument("A direct message needs exactly one membership with member.name") }
        if let type = member["type"] as? String, type != "HUMAN" {
            throw .invalidArgument("The member must be of type HUMAN")
        }
        guard let target = resolveUser(String(rawName.dropFirst("users/".count))) else {
            throw .notFound("User not found: \(rawName)")
        }
        guard target.type == .human else { throw .invalidArgument("The member must be of type HUMAN") }
        guard target.name != account.user.name else {
            throw .invalidArgument("A direct message needs another user")
        }

        let pair: Set<UserName> = [account.user.name, target.name]
        let existing = spaceOrder.compactMap { spaces[$0] }.first { state in
            state.space.type == .directMessage
                && Set(state.members.filter { $0.state == .joined }.map(\.member.name)) == pair
        }
        if let existing { return .json(wireSpace(existing.space)) }

        let name = addSpace(.directMessage, displayName: "", members: [account.user, target], threaded: false)
        for membership in spaces[name]?.members ?? [] {
            record(.membershipCreated(membership), in: name, at: stamp(nil))
        }
        return .json(wireSpace(spaces[name]!.space))
    }

    func searchDirectory(_ incoming: IncomingRequest, _ account: FakeAccount) throws(WireError) -> Reply {
        guard directoryEnabled else { throw .permissionDenied("The caller does not have permission") }
        let mask = Set((incoming.value("readMask") ?? "").split(separator: ",").map(String.init))
        guard !mask.isEmpty else { throw .invalidArgument("readMask is required") }
        let sources = incoming.query.filter { $0.name == "sources" }.compactMap(\.value)
        guard sources.contains("DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE") else {
            throw .invalidArgument("sources must include DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE")
        }
        let query = (incoming.value("query") ?? "").lowercased()
        let paging = try PageRequest.parse(incoming, account: account.user.name, defaultSize: 20, maxSize: 500)
        let matches = knownUsers.values.filter { $0.type == .human }
            .filter { user in
                (user.displayName ?? "").lowercased().hasPrefix(query) || email(for: user).lowercased().hasPrefix(query)
            }
            .sorted { (($0.displayName ?? ""), $0.name) < (($1.displayName ?? ""), $1.name) }
        let (page, next) = paging.slice(matches)
        var body: JSON = [:]
        if !page.isEmpty {
            body["people"] = page.map { user -> JSON in
                var person: JSON = ["resourceName": "people/\(user.name.id(at: 0))"]
                if mask.contains("names"), let name = user.displayName { person["names"] = [["displayName": name]] }
                if mask.contains("emailAddresses") { person["emailAddresses"] = [["value": email(for: user)]] }
                return person
            }
        }
        if let next { body["nextPageToken"] = next }
        return .json(body)
    }

    private func resolveMention(_ id: String) -> (name: UserName, display: String)? {
        if id == "all" { return (UserName(unchecked: "users/all"), "all") }
        guard let name = UserName("users/\(id)"), let user = knownUsers[name] else { return nil }
        return (name, user.displayName ?? id)
    }

    /// Replaces `<users/{id}>` and `<users/all>` with `@DisplayName` and annotates each with UTF-16 offsets.
    func applyMentions(_ text: String) -> (text: String, annotations: [Annotation]) {
        var output = ""
        var annotations: [Annotation] = []
        var cursor = text.startIndex
        while let open = text.range(of: "<users/", range: cursor..<text.endIndex),
            let close = text[open.upperBound...].firstIndex(of: ">")
        {
            output += text[cursor..<open.lowerBound]
            if let mention = resolveMention(String(text[open.upperBound..<close])) {
                let label = "@\(mention.display)"
                annotations.append(
                    Annotation(
                        kind: .userMention(mention.name), startIndex: output.utf16.count, length: label.utf16.count))
                output += label
                cursor = text.index(after: close)
            } else {
                output += text[open]
                cursor = open.upperBound
            }
        }
        output += text[cursor...]
        return (output, annotations)
    }
}
