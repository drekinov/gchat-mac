import ChatModel
import ChatNet
import Foundation

private struct SetUpSpaceBody: Encodable {
    struct SpaceRef: Encodable { var spaceType = "DIRECT_MESSAGE" }
    struct Member: Encodable {
        var name: String
        var type = "HUMAN"
    }
    struct MembershipRef: Encodable { var member: Member }
    var space = SpaceRef()
    var memberships: [MembershipRef]
}

extension Wire {
    struct PeoplePage: Decodable, Sendable {
        struct Person: Decodable, Sendable {
            struct Name: Decodable, Sendable { var displayName: String? }
            struct Email: Decodable, Sendable { var value: String? }
            var resourceName: String?
            var names: [Lossy<Name>]?
            var emailAddresses: [Lossy<Email>]?
        }
        var people: [Lossy<Person>]?
        var nextPageToken: String?
    }

    struct PeopleBatch: Decodable, Sendable {
        struct Response: Decodable, Sendable {
            struct Person: Decodable, Sendable {
                struct Photo: Decodable, Sendable {
                    var url: String?
                    var isDefault: Bool?

                    enum CodingKeys: String, CodingKey {
                        case url
                        case isDefault = "default"
                    }
                }
                var resourceName: String?
                var photos: [Lossy<Photo>]?
            }
            var person: Person?
        }
        var responses: [Lossy<Response>]?
    }
}

extension GoogleChatClient {
    public static let peopleBaseURL = URL(string: "https://people.googleapis.com")!

    public func setUpDirectMessage(with member: DirectMessageMember) async throws(ChatAPIError) -> Space {
        guard let name = member.memberName else {
            throw .invalidArgument(GoogleErrorInfo(httpStatus: 0, status: "CLIENT_INVALID_MEMBER"))
        }
        let body = SetUpSpaceBody(memberships: [.init(member: .init(name: name))])
        let dto: Wire.SpaceDTO = try await send(.post, url("/v1/spaces:setup"), body: body)
        let space = try dto.domain()
        guard space.type == .directMessage else { throw .decoding(path: "spaceType") }
        return space
    }
}

extension GoogleChatClient: PeopleDirectoryAPI {
    public func profilePhotos(for users: [UserName]) async throws(ChatAPIError) -> [UserName: URL] {
        let ids = users.prefix(profilePhotoBatch).map { $0.rawValue.dropFirst("users/".count) }
        guard !ids.isEmpty else { return [:] }
        let items =
            ids.map { URLQueryItem(name: "resourceNames", value: "people/\($0)") } + [
                URLQueryItem(name: "personFields", value: "photos"),
                URLQueryItem(name: "sources", value: "READ_SOURCE_TYPE_PROFILE"),
            ]
        let batch: Wire.PeopleBatch = try await send(
            .get, url("/v1/people:batchGet", query: items, base: Self.peopleBaseURL))
        var result: [UserName: URL] = [:]
        for response in batch.responses ?? [] {
            guard let person = response.value?.person, let resource = person.resourceName,
                resource.hasPrefix("people/"), let user = UserName("users/\(resource.dropFirst("people/".count))"),
                let url = person.photos?.compactMap(\.value).lazy.filter({ $0.isDefault != true })
                    .compactMap({ Mapping.profilePhotoURL($0.url, pixels: 64) }).first
            else { continue }
            result[user] = url
        }
        return result
    }

    public func searchDirectory(_ query: String, pageToken: String?) async throws(ChatAPIError) -> Page<DirectoryPerson>
    {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100 else { return Page(items: [], nextPageToken: nil) }
        var items = [
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "readMask", value: "names,emailAddresses"),
            URLQueryItem(name: "sources", value: "DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"),
            URLQueryItem(name: "pageSize", value: "20"),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let page: Wire.PeoplePage = try await send(
            .get, url("/v1/people:searchDirectoryPeople", query: items, base: Self.peopleBaseURL))
        let raw = page.people ?? []
        let people = raw.compactMap { lossy -> DirectoryPerson? in
            guard let person = lossy.value, let resource = person.resourceName, resource.hasPrefix("people/"),
                let user = UserName("users/\(resource.dropFirst("people/".count))")
            else { return nil }
            let name = person.names?.compactMap(\.value?.displayName).first { !$0.isEmpty }
            let email = person.emailAddresses?.compactMap(\.value?.value).first { !$0.isEmpty }
            guard let display = name ?? email else { return nil }
            return DirectoryPerson(user: user, displayName: display, email: email)
        }
        return Page(
            items: people, nextPageToken: Mapping.pageToken(page.nextPageToken), skipped: raw.count - people.count)
    }
}
