import ChatModel
import ChatNet
import Foundation
import Testing

@testable import GoogleChat

@Suite struct ProfilePhotoTests {
    @Test func photoURLsAreResizedAndRestrictedToGoogleHosts() {
        #expect(
            Mapping.profilePhotoURL("https://lh3.googleusercontent.com/a/ACg8oc123=s100", pixels: 64)?.absoluteString
                == "https://lh3.googleusercontent.com/a/ACg8oc123=s64-c")
        #expect(
            Mapping.profilePhotoURL("https://lh3.googleusercontent.com/a-/AOh14Gx", pixels: 64)?.absoluteString
                == "https://lh3.googleusercontent.com/a-/AOh14Gx=s64-c")
        #expect(Mapping.profilePhotoURL("http://lh3.googleusercontent.com/a/x", pixels: 64) == nil)
        #expect(Mapping.profilePhotoURL("https://evil.example/a/x", pixels: 64) == nil)
        #expect(Mapping.profilePhotoURL("https://googleusercontent.com.evil.example/a", pixels: 64) == nil)
        #expect(Mapping.profilePhotoURL(nil, pixels: 64) == nil)
    }

    @Test func batchGetSkipsDefaultPhotosAndBadEntries() async throws {
        let body = Data(
            """
            {"responses": [
              {"person": {"resourceName": "people/111", "photos": [{"url": "https://lh3.googleusercontent.com/a/one=s100"}]}},
              {"person": {"resourceName": "people/222", "photos": [{"url": "https://lh3.googleusercontent.com/a/two", "default": true}]}},
              {"person": {"resourceName": "people/333", "photos": [{"url": "https://other.example/x"}]}},
              {"status": {"code": 5}},
              "garbage"
            ]}
            """.utf8)
        let transport = StubTransport(body: body)
        let client = makeClient(transport)
        let users = ["111", "222", "333", "444"].map { UserName(unchecked: "users/\($0)") }
        let photos = try await client.profilePhotos(for: users)
        #expect(photos == [users[0]: URL(string: "https://lh3.googleusercontent.com/a/one=s64-c")!])
        let request = try #require(transport.requests.first)
        #expect(request.url.host() == "people.googleapis.com")
        #expect(queryNames(request).filter { $0 == "resourceNames" }.count == 4)
        #expect(queryItems(request)["personFields"] == "photos")
    }

    @Test func emptyUserListMakesNoRequest() async throws {
        let transport = StubTransport(body: Data("{}".utf8))
        #expect(try await makeClient(transport).profilePhotos(for: []).isEmpty)
        #expect(transport.requests.isEmpty)
    }
}
