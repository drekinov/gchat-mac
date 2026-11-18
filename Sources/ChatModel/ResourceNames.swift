import Foundation

/// A Google resource name such as `spaces/AAA/messages/BBB`. Names go into URL paths, so construction validates
/// the collection prefixes and restricts IDs to `[A-Za-z0-9._-]`.
public protocol ResourceName: Hashable, Sendable, Codable, CustomStringConvertible, Comparable {
    /// Collection identifiers, e.g. `["spaces", "messages"]` for `spaces/{s}/messages/{m}`.
    static var pattern: [String] { get }
    var rawValue: String { get }
    init(unchecked rawValue: String)
}

extension ResourceName {
    public init?(_ rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.init(unchecked: rawValue)
    }

    public static func isValid(_ rawValue: String) -> Bool {
        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == pattern.count * 2 else { return false }
        for (index, part) in parts.enumerated() {
            if index.isMultiple(of: 2) {
                guard part == pattern[index / 2] else { return false }
            } else {
                guard isValidID(part) else { return false }
            }
        }
        return true
    }

    static func isValidID(_ id: Substring) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 256, id != ".", id != ".." else { return false }
        return id.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }

    /// The ID segment at collection `index`, e.g. `id(at: 0)` is the space ID of a message name.
    public func id(at index: Int) -> String {
        String(rawValue.split(separator: "/")[index * 2 + 1])
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard Self.isValid(raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid \(Self.self)"))
        }
        self.init(unchecked: raw)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct SpaceName: ResourceName {
    public static let pattern = ["spaces"]
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
}

public struct MessageName: ResourceName {
    public static let pattern = ["spaces", "messages"]
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
    public var space: SpaceName { SpaceName(unchecked: "spaces/\(id(at: 0))") }
}

public struct ThreadName: ResourceName {
    public static let pattern = ["spaces", "threads"]
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
    public var space: SpaceName { SpaceName(unchecked: "spaces/\(id(at: 0))") }
}

public struct UserName: ResourceName {
    public static let pattern = ["users"]
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
    public static let all = UserName(unchecked: "users/all")
}

public struct MembershipName: ResourceName {
    public static let pattern = ["spaces", "members"]
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// `attachmentDataRef.resourceName`, the media ID used by `media.download`.
public struct MediaResourceName: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    /// Media names are opaque and may contain `/`; only path-safe characters are accepted.
    public init?(_ rawValue: String) {
        guard !rawValue.isEmpty, rawValue.utf8.count <= 1024,
            rawValue.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7F && $0 != UInt8(ascii: "?") && $0 != UInt8(ascii: "#") }),
            !rawValue.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0 == ".." || $0.isEmpty
            })
        else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ReactionName: ResourceName {
    public static let pattern = ["spaces", "messages", "reactions"]
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
    public var message: MessageName { MessageName(unchecked: "spaces/\(id(at: 0))/messages/\(id(at: 1))") }
}

public struct CustomEmojiName: ResourceName {
    public static let pattern = ["customEmojis"]
    public let rawValue: String
    public init(unchecked rawValue: String) { self.rawValue = rawValue }
}
