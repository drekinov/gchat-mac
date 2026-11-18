import Foundation

/// Parser for `multipart/related` request bodies (RFC 2046): delimiters are matched as CRLF `--boundary` followed by
/// `--` or optional padding and CRLF, so payload bytes may contain CRLFs, dashes and even a partial boundary.
enum Multipart {
    struct Part {
        /// Lowercased names.
        var headers: [String: String]
        /// Byte offsets into the body that was parsed.
        var range: Range<Int>
    }

    static func boundary(from contentType: String) -> String? {
        let pieces = contentType.split(separator: ";", omittingEmptySubsequences: true)
        guard let type = pieces.first?.trimmingCharacters(in: .whitespaces).lowercased(),
            type == "multipart/related"
        else { return nil }
        for piece in pieces.dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "boundary" else {
                continue
            }
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty || value.utf8.count > 70 ? nil : value
        }
        return nil
    }

    /// Nil when the body isn't well-formed or lacks the closing delimiter.
    static func parse(_ body: Data, boundary: String) -> [Part]? {
        body.withUnsafeBytes { parse($0, boundary: Array(boundary.utf8)) }
    }

    private static let crlf: [UInt8] = [13, 10]
    private static let dashes: [UInt8] = [45, 45]

    private static func parse(_ raw: UnsafeRawBufferPointer, boundary: [UInt8]) -> [Part]? {
        let delimiter = dashes + boundary
        let lineDelimiter = crlf + delimiter
        var parts: [Part] = []

        var position: Int
        if matches(raw, at: 0, delimiter) {
            position = 0
        } else if let found = find(raw, lineDelimiter, from: 0) {
            position = found + 2
        } else {
            return nil
        }

        while true {
            let afterDelimiter = position + delimiter.count
            if matches(raw, at: afterDelimiter, dashes) { return parts.isEmpty ? nil : parts }
            guard let headerStart = skipPadding(raw, from: afterDelimiter) else { return nil }

            let bodyStart: Int
            let headerBytes: Range<Int>
            if matches(raw, at: headerStart, crlf) {
                headerBytes = headerStart..<headerStart
                bodyStart = headerStart + 2
            } else if let blank = find(raw, crlf + crlf, from: headerStart) {
                headerBytes = headerStart..<blank
                bodyStart = blank + 4
            } else {
                return nil
            }

            var search = bodyStart
            var next: Int?
            while let candidate = find(raw, lineDelimiter, from: search) {
                let after = candidate + lineDelimiter.count
                if matches(raw, at: after, dashes) || skipPadding(raw, from: after) != nil {
                    next = candidate
                    break
                }
                search = candidate + 1
            }
            guard let next else { return nil }
            let headers = parseHeaders(raw, headerBytes)
            parts.append(Part(headers: headers, range: bodyStart..<next))
            position = next + 2
        }
    }

    /// Returns the index just past the CRLF that ends a delimiter line, or nil when the line holds anything else.
    private static func skipPadding(_ raw: UnsafeRawBufferPointer, from start: Int) -> Int? {
        var index = start
        while index < raw.count, raw[index] == 32 || raw[index] == 9 { index += 1 }
        return matches(raw, at: index, crlf) ? index + 2 : nil
    }

    private static func parseHeaders(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> [String: String] {
        let text = String(decoding: UnsafeRawBufferPointer(rebasing: raw[range]), as: UTF8.self)
        var headers: [String: String] = [:]
        var lastName: String?
        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            if line.first == " " || line.first == "\t", let name = lastName {
                headers[name, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                lastName = name
            }
        }
        return headers
    }

    private static func matches(_ raw: UnsafeRawBufferPointer, at index: Int, _ needle: [UInt8]) -> Bool {
        guard index >= 0, index + needle.count <= raw.count else { return false }
        return needle.withUnsafeBytes { memcmp(raw.baseAddress! + index, $0.baseAddress!, needle.count) == 0 }
    }

    private static func find(_ raw: UnsafeRawBufferPointer, _ needle: [UInt8], from start: Int) -> Int? {
        guard let base = raw.baseAddress, start >= 0, start + needle.count <= raw.count else { return nil }
        return needle.withUnsafeBytes { pattern in
            guard let hit = memmem(base + start, raw.count - start, pattern.baseAddress!, needle.count) else {
                return nil
            }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }
}
