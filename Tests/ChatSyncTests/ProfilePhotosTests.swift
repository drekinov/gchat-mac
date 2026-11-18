import ChatModel
import Foundation
import GoogleChat
import Synchronization
import Testing

@testable import ChatSync

private final class PhotoDirectory: PeopleDirectoryAPI {
    let photos: [UserName: URL]
    let failing: Bool
    private let calls = Mutex<[[UserName]]>([])

    init(photos: [UserName: URL] = [:], failing: Bool = false) {
        self.photos = photos
        self.failing = failing
    }

    var requested: [[UserName]] { calls.withLock { $0 } }

    func searchDirectory(_ query: String, pageToken: String?) async throws(ChatAPIError) -> Page<DirectoryPerson> {
        Page(items: [], nextPageToken: nil)
    }

    func profilePhotos(for users: [UserName]) async throws(ChatAPIError) -> [UserName: URL] {
        calls.withLock { $0.append(users) }
        if failing { throw .unauthorized }
        return photos.filter { users.contains($0.key) }
    }
}

struct ProfilePhotosTests {
    let alice = UserName(unchecked: "users/1")
    let bob = UserName(unchecked: "users/2")
    let url = URL(string: "https://lh3.googleusercontent.com/a/x=s64-c")!

    @Test func missesAreRememberedSoEachPersonCostsOneLookup() async {
        let directory = PhotoDirectory(photos: [alice: url])
        let photos = ProfilePhotos(directory: directory, clock: ManualClock(start: Timestamp(seconds: 1_000)))
        #expect(await photos.load([alice, bob]) == [alice: url])
        #expect(await photos.load([alice, bob, alice]) == [alice: url])
        #expect(directory.requested == [[alice, bob]])
        #expect(photos.cached(alice) == url)
        #expect(photos.cached(bob) == nil)
    }

    @Test func largeRequestsAreBatched() async {
        let users = (0..<120).map { UserName(unchecked: "users/\($0)") }
        let directory = PhotoDirectory()
        let photos = ProfilePhotos(directory: directory, clock: ManualClock(start: Timestamp(seconds: 1_000)))
        _ = await photos.load(users)
        #expect(directory.requested.map(\.count) == [50, 50, 20])
    }

    @Test func failuresPauseLookupsThenRetry() async {
        let clock = ManualClock(start: Timestamp(seconds: 1_000))
        let directory = PhotoDirectory(failing: true)
        let photos = ProfilePhotos(directory: directory, clock: clock)
        #expect(await photos.load([alice]).isEmpty)
        #expect(await photos.load([alice]).isEmpty)
        #expect(directory.requested.count == 1)
        clock.advance(.seconds(601))
        _ = await photos.load([alice])
        #expect(directory.requested.count == 2)
    }
}
