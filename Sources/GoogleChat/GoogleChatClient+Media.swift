import ChatModel
import ChatNet
import Foundation

private struct UploadMetadata: Encodable {
    var filename: String
}

private struct UploadResponse: Decodable {
    struct DataRef: Decodable {
        var resourceName: String?
        var attachmentUploadToken: String
    }
    var attachmentDataRef: DataRef
}

extension GoogleChatClient: ChatMediaAPI {
    static let maxUploadBytes = 200 * 1024 * 1024
    static let maxFilenameBytes = 255
    static let defaultContentType = "application/octet-stream"

    public func uploadAttachment(
        to space: SpaceName, file: URL, filename: String, contentType: String
    ) async throws(ChatAPIError) -> UploadedAttachment {
        let opened = try Self.openUploadFile(file)
        let boundary = Self.makeBoundary()
        let metadata: Data
        do {
            metadata = try JSONEncoder.chat.encode(UploadMetadata(filename: Self.sanitizedFilename(filename)))
        } catch {
            throw .decoding(path: "request")
        }
        var prefix = Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)
        prefix.append(metadata)
        prefix.append(Data("\r\n--\(boundary)\r\nContent-Type: \(Self.validContentType(contentType))\r\n\r\n".utf8))
        let body = FileBody(prefix: prefix, opened: opened, suffix: Data("\r\n--\(boundary)--\r\n".utf8))

        let url = url(
            "/upload/v1/\(space.rawValue)/attachments:upload", query: [.init(name: "uploadType", value: "multipart")])
        let response = try await authorizedRequest { token in
            HTTPRequest(
                method: .post, url: url,
                headers: [
                    "Authorization": "Bearer \(token)", "Accept": "application/json",
                    "Content-Type": "multipart/related; boundary=\(boundary)",
                ],
                timeout: .seconds(60), maxResponseBytes: 1 << 20, bodyFile: body)
        }
        let decoded = try Self.decode(UploadResponse.self, from: response.body)
        guard !decoded.attachmentDataRef.attachmentUploadToken.isEmpty else {
            throw .decoding(path: "attachmentDataRef.attachmentUploadToken")
        }
        return UploadedAttachment(
            resourceName: decoded.attachmentDataRef.resourceName.flatMap { MediaResourceName($0) },
            uploadToken: decoded.attachmentDataRef.attachmentUploadToken)
    }

    public func downloadMedia(
        _ resource: MediaResourceName, maxBytes: Int, onChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws(ChatAPIError) -> MediaDownload {
        let segments = resource.rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(".") else {
            throw .invalidArgument(GoogleErrorInfo(httpStatus: 0, status: "CLIENT_BAD_RESOURCE_NAME"))
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath =
            "/v1/media/"
            + segments.map { $0.addingPercentEncoding(withAllowedCharacters: .queryValue)! }.joined(separator: "/")
        components.percentEncodedQueryItems = [URLQueryItem(name: "alt", value: "media")]
        let url = components.url!

        var refreshed = false
        while true {
            let token = try await tokens.accessToken()
            let request = HTTPRequest(
                method: .get, url: url, headers: ["Authorization": "Bearer \(token)", "Accept": "*/*"],
                timeout: .seconds(60), maxResponseBytes: maxBytes)
            let head: HTTPResponseHead
            do throws(TransportError) {
                if let streaming = transport as? any StreamingTransport {
                    head = try await streaming.stream(request, onChunk: onChunk)
                } else {
                    let response = try await transport.send(request)
                    if (200..<300).contains(response.status), !response.body.isEmpty {
                        do { try onChunk(response.body) } catch { throw .sinkFailed }
                    }
                    head = HTTPResponseHead(
                        status: response.status, headers: response.headers,
                        byteCount: (200..<300).contains(response.status) ? response.body.count : 0,
                        errorBody: response.body.prefix(HTTPResponseHead.maxErrorBodyBytes))
                }
            } catch .redirected(let status, let location) {
                guard let location else { throw .transport(.redirected(status: status, location: nil)) }
                return MediaDownload(redirect: location)
            } catch {
                throw .transport(error)
            }
            if (200..<300).contains(head.status) {
                return MediaDownload(contentType: head.headers["content-type"], byteCount: head.byteCount)
            }
            if head.status == 401, !refreshed {
                refreshed = true
                await tokens.invalidate(token)
                continue
            }
            throw ChatAPIError(status: head.status, headers: head.headers, body: head.errorBody)
        }
    }

    /// Like `authorized`, but rebuilds the request for each attempt so a refreshed token is used.
    func authorizedRequest(_ build: (String) -> HTTPRequest) async throws(ChatAPIError) -> HTTPResponse {
        var refreshed = false
        while true {
            let token = try await tokens.accessToken()
            let response: HTTPResponse
            do {
                response = try await transport.send(build(token))
            } catch .redirected(let status, _) {
                throw .transport(.redirected(status: status, location: nil))
            } catch {
                throw .transport(error)
            }
            if (200..<300).contains(response.status) { return response }
            if response.status == 401, !refreshed {
                refreshed = true
                await tokens.invalidate(token)
                continue
            }
            throw ChatAPIError(status: response.status, headers: response.headers, body: response.body)
        }
    }

    /// Opens the file once; the size check and the upload both use this descriptor.
    private static func openUploadFile(_ file: URL) throws(ChatAPIError) -> OpenedFile {
        let opened: OpenedFile
        do {
            opened = try OpenedFile.open(file)
        } catch {
            throw .transport(error)
        }
        guard opened.identity.size <= maxUploadBytes else {
            throw .invalidArgument(GoogleErrorInfo(httpStatus: 0, status: "CLIENT_FILE_TOO_LARGE"))
        }
        return opened
    }

    static func makeBoundary() -> String {
        var generator = SystemRandomNumberGenerator()
        let high = generator.next()
        let low = generator.next()
        return "gchat-" + String(high, radix: 16, uppercase: false).leftPadded(16)
            + String(low, radix: 16, uppercase: false).leftPadded(16)
    }

    /// Replaces control, format, quote and separator characters, then truncates to 255 UTF-8 bytes keeping the
    /// extension.
    static func sanitizedFilename(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                scalars.append("_")
            default:
                scalars.append(scalar == "\"" || scalar == "\\" || scalar == "/" || scalar == "'" ? "_" : scalar)
            }
        }
        var result = String(scalars).trimmingCharacters(in: .whitespaces)
        if result.isEmpty || result == "." || result == ".." { return "file" }
        if result.utf8.count > maxFilenameBytes {
            let ext = (result as NSString).pathExtension
            let suffix = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
            var stem = Substring(result.dropLast(suffix.count))
            while stem.utf8.count + suffix.utf8.count > maxFilenameBytes { stem = stem.dropLast() }
            result = stem + suffix
        }
        return result
    }

    /// Accepts only a bare lowercase-folded `type/subtype`; parameters or anything else become octet-stream.
    static func validContentType(_ value: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespaces).lowercased()
        let parts = lowered.split(separator: "/", omittingEmptySubsequences: false)
        let tokenCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")
        guard parts.count == 2, lowered.utf8.count <= 127,
            parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(tokenCharacters.contains) })
        else { return defaultContentType }
        return lowered
    }
}

extension String {
    fileprivate func leftPadded(_ length: Int) -> String {
        String(repeating: "0", count: max(0, length - count)) + self
    }
}
