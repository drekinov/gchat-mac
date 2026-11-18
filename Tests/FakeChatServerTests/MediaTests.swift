import ChatModel
import ChatNet
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import FakeChatServer

@Suite struct MultipartParsingTests {
    private func parts(_ body: Data, _ boundary: String = "xyzBOUNDARY") -> [Multipart.Part]? {
        Multipart.parse(body, boundary: boundary)
    }

    @Test func parsesTwoParts() throws {
        let body = multipartBody(payload: Data("hello"))
        let result = try #require(parts(body))
        #expect(result.count == 2)
        #expect(result[0].headers["content-type"] == "application/json; charset=UTF-8")
        #expect(String(decoding: body.subdata(in: result[0].range), as: UTF8.self) == #"{"filename":"photo.png"}"#)
        #expect(result[1].headers["content-type"] == "image/png")
        #expect(body.subdata(in: result[1].range) == Data("hello"))
    }

    @Test func binaryPayloadWithDashesCrlfsAndBoundaryLookalikes() throws {
        let boundary = "xyzBOUNDARY"
        var payload = Data()
        payload.append(Data("--\r\n--\r\n\r\n--"))
        payload.append(Data("\r\n--\(boundary.dropLast())"))
        payload.append(Data("\r\n--\(boundary)X more"))
        payload.append(Data("\r\n--\(boundary)-\r\n"))
        payload.append(Data("\r\n\r\n\r\n"))
        payload.append(Data((0...255).map { UInt8($0) }))
        payload.append(Data("--"))
        let body = multipartBody(boundary: boundary, payload: payload)
        let result = try #require(parts(body, boundary))
        #expect(result.count == 2)
        #expect(body.subdata(in: result[1].range) == payload)
    }

    @Test func payloadEndingInCrlfKeepsIt() throws {
        let payload = Data("line\r\n")
        let body = multipartBody(payload: payload)
        let result = try #require(parts(body))
        #expect(body.subdata(in: result[1].range) == payload)
    }

    @Test func emptyPayload() throws {
        let body = multipartBody(payload: Data())
        let result = try #require(parts(body))
        #expect(result[1].range.isEmpty)
    }

    @Test func toleratesPreambleEpilogueAndPadding() throws {
        var body = Data("This is a preamble\r\n")
        body.append(
            Data("--b \t\r\nContent-Type: application/json\r\n\r\n{}\r\n--b\r\n\r\nraw\r\n--b--\r\ntrailing epilogue"))
        let result = try #require(parts(body, "b"))
        #expect(result.count == 2)
        #expect(result[1].headers.isEmpty)
        #expect(body.subdata(in: result[1].range) == Data("raw"))
    }

    @Test func headerNamesAreCaseInsensitiveAndFolded() throws {
        let body = Data("--b\r\nCONTENT-type: text/plain;\r\n charset=utf-8\r\n\r\nx\r\n--b--\r\n")
        let result = try #require(parts(body, "b"))
        #expect(result[0].headers["content-type"] == "text/plain; charset=utf-8")
    }

    @Test(arguments: [
        "", "no boundary at all", "--xyzBOUNDARY\r\n\r\nbody without closing",
        "--xyzBOUNDARY--\r\n", "--xyzBOUNDARY\r\nContent-Type: a\r\nbody",
    ])
    func rejectsMalformedBodies(_ text: String) {
        #expect(parts(Data(text)) == nil)
    }

    @Test func truncatedBodiesAreRejected() {
        let body = multipartBody(payload: bytes(500))
        for cut in [3, 5, 40, body.count / 2, body.count - 3] {
            #expect(parts(body.prefix(body.count - cut)) == nil)
        }
    }

    @Test func extractsTheBoundaryParameter() {
        #expect(Multipart.boundary(from: "multipart/related; boundary=abc") == "abc")
        #expect(Multipart.boundary(from: "Multipart/Related;Boundary=\"a b=c\"; charset=x") == "a b=c")
        #expect(Multipart.boundary(from: "multipart/related") == nil)
        #expect(Multipart.boundary(from: "multipart/form-data; boundary=abc") == nil)
        #expect(Multipart.boundary(from: "application/json; boundary=abc") == nil)
        #expect(Multipart.boundary(from: "multipart/related; boundary=") == nil)
    }
}

@Suite struct UploadTests {
    let h = Harness()

    @Test func storesTheUploadAndReturnsADataRef() async throws {
        let payload = bytes(10_000)
        let call = try await h.upload(payload, filename: "cat.png", type: "image/png")
        #expect(call.status == 200)
        let ref = try #require(call.json["attachmentDataRef"] as? [String: Any])
        let resource = try #require(ref["resourceName"] as? String)
        let token = try #require(ref["attachmentUploadToken"] as? String)
        #expect(resource.hasPrefix("fake-media/"))
        #expect(!token.isEmpty && !resource.contains(token))
        #expect(h.server.mediaBytes(try #require(MediaResourceName(resource))) == payload)
        #expect(call.headers["content-type"]?.hasPrefix("application/json") == true)
    }

    @Test func aBinaryPayloadWithBoundaryLikeSequencesSurvivesTheWire() async throws {
        var payload = Data("--\r\n--xyzBOUNDARY".dropLast().utf8)
        payload.append(Data("\r\n--xyzBOUNDARYX\r\n\r\n".utf8))
        payload.append(bytes(3000, seed: 9))
        payload.append(Data("\r\n--".utf8))
        let uploaded = try await h.uploaded(payload)
        let download = try await h.download(uploaded.resource, as: h.alice)
        #expect(download.body == payload)
    }

    @Test func aMissingMediaPartTypeDefaultsToOctetStream() async throws {
        let call = try await h.upload(Data("abc"), type: nil)
        let ref = try #require(call.json["attachmentDataRef"] as? [String: Any])
        let download = try await h.download(try #require(ref["resourceName"] as? String), as: h.alice)
        #expect(download.headers["content-type"] == "application/octet-stream")
    }

    @Test func aQuotedBoundaryWorks() async throws {
        let body = multipartBody(boundary: "a=b c", payload: Data("data"))
        let call = try await h.raw(
            .post, path: "/upload/v1/\(h.space.rawValue)/attachments:upload", query: ["uploadType": "multipart"],
            headers: ["Content-Type": "multipart/related; boundary=\"a=b c\""], body: body, as: h.alice)
        #expect(call.status == 200)
    }

    @Test func membershipAndAuthAreEnforced() async throws {
        #expect(try await h.upload(Data("x"), as: h.carol).status == 403)
        #expect(try await h.upload(Data("x"), as: h.carol).errorStatus == "PERMISSION_DENIED")
        #expect(
            try await h.raw(.post, path: "/upload/v1/\(h.space.rawValue)/attachments:upload", as: nil).status == 401)
        let unknown = SpaceName(unchecked: "spaces/NOPE")
        #expect(try await h.upload(Data("x"), to: unknown, as: h.alice).status == 404)
        #expect(try await h.upload(Data("x"), as: h.alice).status == 200)
    }

    @Test func rejectsBadRequests() async throws {
        let path = "/upload/v1/\(h.space.rawValue)/attachments:upload"
        let good = multipartBody(payload: Data("x"))
        let related = ["Content-Type": "multipart/related; boundary=xyzBOUNDARY"]

        let simple = try await h.raw(
            .post, path: path, query: ["uploadType": "media"], headers: related, body: good, as: h.alice)
        let noType = try await h.raw(.post, path: path, query: [:], headers: related, body: good, as: h.alice)
        let wrongContentType = try await h.raw(
            .post, path: path, query: ["uploadType": "multipart"],
            headers: ["Content-Type": "application/json"], body: good, as: h.alice)
        let garbage = try await h.raw(
            .post, path: path, query: ["uploadType": "multipart"], headers: related, body: Data("nonsense"),
            as: h.alice)
        let noFilename = try await h.raw(
            .post, path: path, query: ["uploadType": "multipart"], headers: related,
            body: multipartBody(metadata: "{}", payload: Data("x")), as: h.alice)
        let notJSON = try await h.raw(
            .post, path: path, query: ["uploadType": "multipart"], headers: related,
            body: multipartBody(metadata: "not json", payload: Data("x")), as: h.alice)
        for call in [simple, noType, wrongContentType, garbage, noFilename, notJSON] {
            #expect(call.status == 400)
            #expect(call.errorStatus == "INVALID_ARGUMENT")
        }
        #expect(h.server.requests.filter { $0.path.hasSuffix("attachments:upload") }.count == 6)
    }

    @Test func enforcesTheSizeLimit() async throws {
        #expect(FakeChatServer.defaultMaxUploadBytes == 200 * 1024 * 1024)
        #expect(h.server.maxUploadBytes == FakeChatServer.defaultMaxUploadBytes)
        h.server.maxUploadBytes = 4096
        #expect(try await h.upload(bytes(4096)).status == 200)
        let tooBig = try await h.upload(bytes(4097))
        #expect(tooBig.status == 400)
        #expect(tooBig.errorStatus == "INVALID_ARGUMENT")
    }

    @Test func uploadsAboveEightMegabytesLiveInATempFile() async throws {
        let payload = bytes(9 * 1024 * 1024 + 5)
        let uploaded = try await h.uploaded(payload)
        let resource = try #require(MediaResourceName(uploaded.resource))
        #expect(h.server.mediaBytes(resource) == payload)

        let whole = try await h.download(uploaded.resource, as: h.alice)
        #expect(whole.status == 200)
        #expect(whole.body == payload)
        let slice = try await h.download(uploaded.resource, range: "bytes=9000000-9000019", as: h.alice)
        #expect(slice.status == 206)
        #expect(slice.body == payload.subdata(in: 9_000_000..<9_000_020))
    }

    @Test func smallUploadsStayInMemory() async throws {
        let uploaded = try await h.uploaded(bytes(100))
        #expect(h.server.mediaBytes(try #require(MediaResourceName(uploaded.resource))) != nil)
    }

    @Test func anUploadedFileBecomesAnAttachmentOfThePostedMessage() async throws {
        let payload = bytes(2000)
        let call = try await h.upload(payload, filename: "report.pdf", type: "application/pdf")
        let ref = try #require(call.json["attachmentDataRef"] as? [String: Any])
        let token = try #require(ref["attachmentUploadToken"] as? String)

        let created = try await h.createWithAttachment(token)
        #expect(created.status == 200)
        let attachment = try #require(created.items("attachment").first)
        #expect(attachment["source"] as? String == "UPLOADED_CONTENT")
        #expect(attachment["contentName"] as? String == "report.pdf")
        #expect(attachment["contentType"] as? String == "application/pdf")
        let dataRef = try #require(attachment["attachmentDataRef"] as? [String: Any])
        #expect(dataRef["resourceName"] as? String == ref["resourceName"] as? String)

        let message = try #require(h.server.messages(in: h.space).last)
        #expect(message.attachments.first?.contentName == "report.pdf")
        let bobDownload = try await h.download(try #require(dataRef["resourceName"] as? String), as: h.bob)
        #expect(bobDownload.body == payload)
    }

    @Test func tokensAreOnlyValidInTheirOwnSpace() async throws {
        let other = h.server.addSpace(.space, displayName: "Other", members: [h.alice, h.bob])
        let uploaded = try await h.uploaded(bytes(100), to: h.space)

        let wrong = try await h.createWithAttachment(uploaded.token, in: other)
        #expect(wrong.status == 400)
        #expect(wrong.errorStatus == "INVALID_ARGUMENT")
        #expect(h.server.messages(in: other).isEmpty)
        #expect(try await h.createWithAttachment(uploaded.token, in: h.space).status == 200)

        let unknown = try await h.createWithAttachment("never-issued")
        #expect(unknown.status == 400)
        let missing = try await h.call(
            .post, "\(h.space.rawValue)/messages", body: ["attachment": [["attachmentDataRef": [String: String]()]]],
            as: h.alice)
        #expect(missing.status == 400)
    }

    @Test func failureRulesRouteUploads() async throws {
        h.server.fail(.rateLimited(route: .uploadAttachment, retryAfter: 3))
        let limited = try await h.upload(Data("x"))
        #expect(limited.status == 429)
        #expect(limited.headers["retry-after"] == "3")
        #expect(try await h.upload(Data("x")).status == 200)

        h.server.fail(.networkError(.networkConnectionLost, route: .uploadAttachment))
        await #expect(throws: TransportError.self) { try await h.upload(Data("x")) }
    }
}

@Suite struct DownloadTests {
    let h = Harness()
    let payload = bytes(1000)

    private func resource() async throws -> String {
        try await h.uploaded(payload).resource
    }

    @Test func returnsBytesWithHeaders() async throws {
        let name = try await resource()
        let call = try await h.download(name, as: h.bob)
        #expect(call.status == 200)
        #expect(call.body == payload)
        #expect(call.headers["content-type"] == "image/png")
        #expect(call.headers["content-length"] == "1000")
        #expect(call.headers["accept-ranges"] == "bytes")
    }

    @Test func withoutAltMediaReturnsMetadata() async throws {
        let name = try await resource()
        let call = try await h.raw(.get, path: "/v1/media/\(name)", as: h.alice)
        #expect(call.status == 200)
        #expect(call.json["resourceName"] as? String == name)
    }

    @Test(arguments: [
        ("bytes=0-9", 0, 10), ("bytes=990-", 990, 1000), ("bytes=-10", 990, 1000), ("bytes=5-5", 5, 6),
        ("bytes=990-5000", 990, 1000), ("bytes=0-0", 0, 1),
    ])
    func rangeRequests(header: String, lower: Int, upper: Int) async throws {
        let name = try await resource()
        let call = try await h.download(name, range: header, as: h.alice)
        #expect(call.status == 206)
        #expect(call.body == payload.subdata(in: lower..<upper))
        #expect(call.headers["content-range"] == "bytes \(lower)-\(upper - 1)/1000")
        #expect(call.headers["content-length"] == String(upper - lower))
    }

    @Test(arguments: ["bytes=1000-", "bytes=2000-3000", "bytes=-0", "bytes=9-5"])
    func unsatisfiableRanges(header: String) async throws {
        let call = try await h.download(try await resource(), range: header, as: h.alice)
        #expect(call.status == 416)
        #expect(call.headers["content-range"] == "bytes */1000")
    }

    @Test(arguments: ["bytes=0-1,5-6", "items=0-5", "bytes=abc", "bytes=-", "bytes=--5"])
    func unsupportedRangesServeTheWholeFile(header: String) async throws {
        let call = try await h.download(try await resource(), range: header, as: h.alice)
        #expect(call.status == 200)
        #expect(call.body == payload)
    }

    @Test func nonMembersUnknownAndUnauthenticated() async throws {
        let name = try await resource()
        let forbidden = try await h.download(name, as: h.carol)
        #expect(forbidden.status == 403)
        #expect(forbidden.errorStatus == "PERMISSION_DENIED")
        let unknown = try await h.download("fake-media/missing", as: h.alice)
        #expect(unknown.status == 404)
        #expect(unknown.errorStatus == "NOT_FOUND")
        #expect(try await h.download(name, as: nil).status == 401)
        #expect(try await h.download(name, as: h.alice).status == 200)
    }

    @Test func accessFollowsMembership() async throws {
        let name = try await resource()
        h.server.removeMember(h.bob, from: h.space)
        #expect(try await h.download(name, as: h.bob).status == 403)
        h.server.addMember(h.carol, to: h.space)
        #expect(try await h.download(name, as: h.carol).body == payload)
    }

    @Test func seededMediaIsDownloadableOnceAMessageAttachesIt() async throws {
        let media = h.server.addMedia(bytes(300), contentType: "image/gif", filename: "loop.gif")
        #expect(try await h.download(media.rawValue, as: h.alice).status == 403)

        let message = h.server.postMedia([media], text: "look", in: h.space, from: .account(h.bob))
        let attachment = try #require(message.attachments.first)
        #expect(attachment.contentName == "loop.gif")
        #expect(attachment.contentType == "image/gif")
        #expect(attachment.source == .uploaded(media))

        let call = try await h.download(media.rawValue, as: h.alice)
        #expect(call.status == 200)
        #expect(call.headers["content-type"] == "image/gif")
        #expect(try await h.download(media.rawValue, as: h.carol).status == 403)

        let listed = try await h.listMessages()
        let wire = try #require(listed.items("messages").last?["attachment"] as? [[String: Any]])
        #expect((wire[0]["attachmentDataRef"] as? [String: Any])?["resourceName"] as? String == media.rawValue)
    }

    @Test func seededMediaAttachedByPostIsAccessibleToThatSpaceOnly() async throws {
        let other = h.server.addSpace(.space, members: [h.carol])
        let media = h.server.addMedia(bytes(10), contentType: "text/plain", filename: "n.txt")
        h.server.post(
            "", in: other, from: .account(h.carol),
            attachments: [Attachment(contentName: "n.txt", contentType: "text/plain", source: .uploaded(media))])
        #expect(try await h.download(media.rawValue, as: h.carol).status == 200)
        #expect(try await h.download(media.rawValue, as: h.alice).status == 403)
    }

    @Test func failureRulesRouteDownloads() async throws {
        let name = try await resource()
        h.server.fail(.unavailable(route: .downloadMedia))
        #expect(try await h.download(name, as: h.alice).status == 503)
        #expect(try await h.download(name, as: h.alice).status == 200)

        h.server.fail(.permissionDenied(route: .downloadMedia, account: h.bob, times: nil))
        #expect(try await h.download(name, as: h.bob).status == 403)
        #expect(try await h.download(name, as: h.alice).status == 200)
    }

    @Test func requestsAreRecorded() async throws {
        let name = try await resource()
        _ = try await h.download(name, range: "bytes=0-4", as: h.alice)
        let recorded = try #require(h.server.requests.last)
        #expect(recorded.path == "/v1/media/\(name)")
        #expect(recorded.value(for: "alt") == "media")
        #expect(recorded.status == 206)
        #expect(recorded.account == h.alice)
    }
}

@Suite struct MediaRedirectTests {
    let h = Harness()
    let payload = bytes(2500)

    private func hostSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeMediaHost.self]
        return URLSession(configuration: configuration)
    }

    private func redirectTarget(_ name: String, range: String? = nil) async throws -> URL {
        do {
            _ = try await h.download(name, range: range, as: h.alice)
            Issue.record("expected a redirect")
        } catch let error as TransportError {
            guard case .redirected(let status, let location) = error else { throw error }
            #expect(status == 302)
            return try #require(location)
        }
        throw CancellationError()
    }

    @Test func downloadsRedirectToTheMediaHost() async throws {
        let name = try await h.uploaded(payload).resource
        h.server.mediaRedirectHost = "media.fake-gstatic.example"
        let target = try await redirectTarget(name)
        #expect(target.scheme == "https")
        #expect(target.host() == "media.fake-gstatic.example")
        #expect(target.path.count > 1)
        #expect(!target.absoluteString.contains(name))
        #expect(!target.absoluteString.contains(h.alice.token))
    }

    @Test func theMediaHostServesTheBytesWithoutCredentials() async throws {
        let name = try await h.uploaded(payload).resource
        h.server.mediaRedirectHost = "media.fake-gstatic.example"
        let target = try await redirectTarget(name)

        let (data, response) = try await hostSession().data(from: target)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(data == payload)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "image/png")

        var ranged = URLRequest(url: target)
        ranged.setValue("bytes=100-199", forHTTPHeaderField: "Range")
        let (part, partResponse) = try await hostSession().data(for: ranged)
        #expect((partResponse as? HTTPURLResponse)?.statusCode == 206)
        #expect(part == payload.subdata(in: 100..<200))

        let log = h.server.mediaHostRequests
        #expect(log.count == 2)
        #expect(log.allSatisfy { !$0.hadCredentials && $0.host == "media.fake-gstatic.example" })
        #expect(log.map(\.status) == [200, 206])
        #expect(log.last?.range == "bytes=100-199")
    }

    @Test func rangeRequestsRedirectToo() async throws {
        let name = try await h.uploaded(payload).resource
        h.server.mediaRedirectHost = "media.fake-gstatic.example"
        let target = try await redirectTarget(name, range: "bytes=0-9")
        #expect(target.host() == "media.fake-gstatic.example")
    }

    @Test func credentialsSentToTheMediaHostAreReported() async throws {
        let name = try await h.uploaded(payload).resource
        h.server.mediaRedirectHost = "media.fake-gstatic.example"
        var request = URLRequest(url: try await redirectTarget(name))
        request.setValue("Bearer \(h.alice.token)", forHTTPHeaderField: "Authorization")
        _ = try await hostSession().data(for: request)
        #expect(h.server.mediaHostRequests.last?.hadCredentials == true)
    }

    @Test func unknownTokensAndMethodsAreRejected() async throws {
        let session = hostSession()
        let (_, missing) = try await session.data(from: URL(string: "https://media.fake-gstatic.example/nope")!)
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)

        let name = try await h.uploaded(payload).resource
        h.server.mediaRedirectHost = "media.fake-gstatic.example"
        var post = URLRequest(url: try await redirectTarget(name))
        post.httpMethod = "POST"
        let (_, response) = try await session.data(for: post)
        #expect((response as? HTTPURLResponse)?.statusCode == 405)
    }

    @Test func redirectModeCanBeTurnedOff() async throws {
        let name = try await h.uploaded(payload).resource
        h.server.mediaRedirectHost = "media.fake-gstatic.example"
        _ = try await redirectTarget(name)
        h.server.mediaRedirectHost = nil
        #expect(try await h.download(name, as: h.alice).body == payload)
    }

    @Test func redirectedDownloadsStillCheckMembership() async throws {
        let name = try await h.uploaded(payload).resource
        h.server.mediaRedirectHost = "media.fake-gstatic.example"
        #expect(try await h.download(name, as: h.carol).status == 403)
        #expect(try await h.download("fake-media/missing", as: h.alice).status == 404)
    }

    @Test func tokensDoNotLeakAcrossServers() async throws {
        let other = Harness()
        let name = try await h.uploaded(payload).resource
        h.server.mediaRedirectHost = "media.fake-gstatic.example"
        let target = try await redirectTarget(name)
        #expect(other.server.mediaHostRequests.isEmpty)
        let (data, _) = try await hostSession().data(from: target)
        #expect(data == payload)
        #expect(other.server.mediaHostRequests.isEmpty)
        #expect(h.server.mediaHostRequests.count == 1)
    }
}

@Suite struct FakeMediaGenerationTests {
    private func properties(_ data: Data) throws -> (width: Int, height: Int, frames: Int, type: String) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let info = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (
            info[kCGImagePropertyPixelWidth] as? Int ?? 0, info[kCGImagePropertyPixelHeight] as? Int ?? 0,
            CGImageSourceGetCount(source), CGImageSourceGetType(source) as String? ?? ""
        )
    }

    private func firstPixel(_ data: Data) throws -> [UInt8] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(
            CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(pixel.prefix(3))
    }

    @Test func pngHasTheRequestedSizeAndColour() throws {
        let data = FakeMedia.png(width: 40, height: 24, color: FakeMedia.Color(red: 200, green: 10, blue: 30))
        let info = try properties(data)
        #expect((info.width, info.height, info.frames) == (40, 24, 1))
        #expect(info.type == "public.png")
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let pixel = try firstPixel(data)
        #expect(abs(Int(pixel[0]) - 200) <= 2 && abs(Int(pixel[1]) - 10) <= 2 && abs(Int(pixel[2]) - 30) <= 2)
    }

    @Test func jpegHasTheRequestedSize() throws {
        let data = FakeMedia.jpeg(width: 33, height: 17, color: .green)
        let info = try properties(data)
        #expect((info.width, info.height, info.frames) == (33, 17, 1))
        #expect(info.type == "public.jpeg")
        #expect(Array(data.prefix(3)) == [0xFF, 0xD8, 0xFF])
        #expect(try firstPixel(data)[1] > 140)
    }

    @Test func gifIsAnimated() throws {
        let data = FakeMedia.gif(width: 20, height: 12, colors: [.red, .green, .blue, .yellow])
        let info = try properties(data)
        #expect((info.width, info.height, info.frames) == (20, 12, 4))
        #expect(info.type == "com.compuserve.gif")
        #expect(Array(data.prefix(4)) == Array("GIF8".utf8))
    }

    @Test func imagesAreDeterministic() {
        #expect(FakeMedia.png(width: 50, height: 50, color: .red) == FakeMedia.png(width: 50, height: 50, color: .red))
        #expect(FakeMedia.jpeg(width: 50, height: 50) == FakeMedia.jpeg(width: 50, height: 50))
        #expect(FakeMedia.gif() == FakeMedia.gif())
        #expect(FakeMedia.png(color: .red) != FakeMedia.png(color: .blue))
    }

    @Test func pdfHasTheRequestedPages() throws {
        let data = FakeMedia.pdf(pages: 3, title: "Quarterly")
        #expect(Array(data.prefix(5)) == Array("%PDF-".utf8))
        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        #expect(document.numberOfPages == 3)
    }

    @Test func generatedMediaRoundTripsThroughTheServer() async throws {
        let h = Harness()
        let png = FakeMedia.png(width: 8, height: 8)
        let media = h.server.addMedia(png, contentType: "image/png", filename: "tile.png")
        h.server.postMedia([media], in: h.space, from: .account(h.alice))
        #expect(try await h.download(media.rawValue, as: h.bob).body == png)
    }
}
