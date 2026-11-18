import Foundation
import Testing

@testable import ChatModel

struct TimestampTests {
    @Test(arguments: [
        ("1970-01-01T00:00:00Z", Int64(0), Int32(0)),
        ("2026-10-14T12:34:56.789Z", Int64(1_791_981_296), Int32(789_000_000)),
        ("2026-10-14T12:34:56.123456789Z", Int64(1_791_981_296), Int32(123_456_789)),
        ("2026-10-14T15:34:56.5+03:00", Int64(1_791_981_296), Int32(500_000_000)),
        ("1969-12-31T23:59:59.999999999Z", Int64(-1), Int32(999_999_999)),
        ("2000-02-29T00:00:00Z", Int64(951_782_400), Int32(0)),
    ])
    func parses(text: String, seconds: Int64, nanos: Int32) throws {
        let parsed = try #require(Timestamp(rfc3339: text))
        #expect(parsed == Timestamp(seconds: seconds, nanos: nanos))
    }

    @Test(arguments: [
        "", "2026-10-14", "2026-10-14T12:34:56", "2026-13-01T00:00:00Z", "2026-10-14T12:34:56.Z",
        "2026-10-14T12:34:56.1234567890Z", "2026-10-14T12:34:56Zjunk", "2026-10-14T12:34:56+0300",
    ])
    func rejects(text: String) {
        #expect(Timestamp(rfc3339: text) == nil)
    }

    @Test(arguments: [
        "2026-10-14T12:34:56Z", "2026-10-14T12:34:56.789Z", "2026-10-14T12:34:56.000001Z",
        "2026-10-14T12:34:56.123456789Z", "1969-12-31T23:59:59.999999999Z",
    ])
    func roundTripsExactly(text: String) throws {
        #expect(try #require(Timestamp(rfc3339: text)).rfc3339 == text)
    }

    @Test func ordersByNanos() throws {
        let a = try #require(Timestamp(rfc3339: "2026-10-14T12:00:00.000000001Z"))
        let b = try #require(Timestamp(rfc3339: "2026-10-14T12:00:00.000000002Z"))
        #expect(a < b)
    }

    @Test func addsNegativeAndPositiveDurations() {
        let t = Timestamp(seconds: 100, nanos: 500_000_000)
        #expect(t.adding(.seconds(-2)) == Timestamp(seconds: 98, nanos: 500_000_000))
        #expect(t.adding(.milliseconds(600)) == Timestamp(seconds: 101, nanos: 100_000_000))
        #expect(t.adding(.milliseconds(-600)) == Timestamp(seconds: 99, nanos: 900_000_000))
    }

    @Test func codableUsesRFC3339() throws {
        let t = Timestamp(seconds: 1_791_981_296, nanos: 789_000_000)
        let data = try JSONEncoder().encode([t])
        #expect(String(decoding: data, as: UTF8.self) == #"["2026-10-14T12:34:56.789Z"]"#)
        #expect(try JSONDecoder().decode([Timestamp].self, from: data) == [t])
    }
}

struct ResourceNameTests {
    @Test func validNames() throws {
        let message = try #require(MessageName("spaces/AAAA1234/messages/Bx.Yz-_9"))
        #expect(message.space == SpaceName("spaces/AAAA1234"))
        #expect(ThreadName("spaces/A/threads/t1")?.space.rawValue == "spaces/A")
        #expect(UserName("users/123") != nil)
        #expect(MembershipName("spaces/A/members/users/1") == nil)
    }

    @Test(arguments: [
        "", "spaces", "spaces/", "spaces/A/", "spaces/A/messages", "spaces/../messages/x", "spaces/A%2F/messages/x",
        "spaces/A/messages/x/extra", "Spaces/A", "spaces/A?x=1", "spaces/A#f", "spaces/A B", "spaces/.",
    ])
    func rejectsPathTricks(raw: String) {
        #expect(SpaceName(raw) == nil)
        #expect(MessageName(raw) == nil)
    }

    @Test func decodingValidates() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([SpaceName].self, from: Data(#"["spaces/../x"]"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([UserName].self, from: Data(#"["spaces/A"]"#.utf8))
        }
    }

    @Test func mediaNamesAllowSlashesButNotTraversal() {
        #expect(MediaResourceName("ClxDaGF0/abc_def=") != nil)
        #expect(MediaResourceName("a/../b") == nil)
        #expect(MediaResourceName("a//b") == nil)
        #expect(MediaResourceName("a?alt=json") == nil)
        #expect(MediaResourceName("a b") == nil)
    }
}
