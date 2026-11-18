import Foundation

/// An RFC 3339 instant with nanosecond precision. Server timestamps round-trip exactly, so they can be compared,
/// used as version stamps and sent back in filters without `Date`'s floating-point loss.
public struct Timestamp: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let seconds: Int64
    public let nanos: Int32

    public init(seconds: Int64, nanos: Int32 = 0) {
        precondition((0..<1_000_000_000).contains(nanos))
        self.seconds = seconds
        self.nanos = nanos
    }

    public init(_ date: Date) {
        let interval = date.timeIntervalSince1970
        var seconds = Int64(interval.rounded(.down))
        var nanos = Int32(((interval - Double(seconds)) * 1e9).rounded())
        if nanos >= 1_000_000_000 {
            seconds += 1
            nanos -= 1_000_000_000
        }
        self.init(seconds: seconds, nanos: nanos)
    }

    public var date: Date { Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1e9) }

    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.seconds, lhs.nanos) < (rhs.seconds, rhs.nanos) }

    public func adding(_ duration: Duration) -> Timestamp {
        let (durationSeconds, attoseconds) = duration.components
        let totalNanos = Int64(nanos) + attoseconds / 1_000_000_000
        let carry = totalNanos >= 0 ? totalNanos / 1_000_000_000 : (totalNanos - 999_999_999) / 1_000_000_000
        return Timestamp(
            seconds: seconds + durationSeconds + carry, nanos: Int32(totalNanos - carry * 1_000_000_000))
    }

    /// Accepts `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)` with up to 9 fractional digits.
    public init?(rfc3339 text: String) {
        let bytes = Array(text.utf8)
        guard bytes.count >= 20 else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                guard index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) else {
                    return nil
                }
                value = value * 10 + Int(bytes[index] - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = number(0..<4), bytes[4] == UInt8(ascii: "-"), let month = number(5..<7),
            bytes[7] == UInt8(ascii: "-"), let day = number(8..<10),
            bytes[10] == UInt8(ascii: "T") || bytes[10] == UInt8(ascii: "t"),
            let hour = number(11..<13), bytes[13] == UInt8(ascii: ":"), let minute = number(14..<16),
            bytes[16] == UInt8(ascii: ":"), let second = number(17..<19),
            (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }

        var index = 19
        var nanos = 0
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            var digits = 0
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                guard digits < 9 else { return nil }
                nanos = nanos * 10 + Int(bytes[index] - UInt8(ascii: "0"))
                digits += 1
                index += 1
            }
            guard digits > 0 else { return nil }
            for _ in digits..<9 { nanos *= 10 }
        }

        var offset = 0
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "Z"), UInt8(ascii: "z"):
            guard index + 1 == bytes.count else { return nil }
        case UInt8(ascii: "+"), UInt8(ascii: "-"):
            guard index + 6 == bytes.count, let offsetHour = number(index + 1..<index + 3),
                bytes[index + 3] == UInt8(ascii: ":"), let offsetMinute = number(index + 4..<index + 6)
            else { return nil }
            offset = (offsetHour * 3600 + offsetMinute * 60) * (bytes[index] == UInt8(ascii: "+") ? 1 : -1)
        default:
            return nil
        }

        let days = Self.daysFromCivil(year: year, month: month, day: day)
        let seconds = Int64(days) * 86_400 + Int64(hour * 3600 + minute * 60 + min(second, 59)) - Int64(offset)
        self.init(seconds: seconds, nanos: Int32(nanos))
    }

    /// UTC, with the shortest of 0, 3, 6 or 9 fractional digits that is exact.
    public var rfc3339: String {
        let days = seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400
        let secondOfDay = Int(seconds - days * 86_400)
        let (year, month, day) = Self.civilFromDays(Int(days))
        var text = String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, secondOfDay / 3600, secondOfDay / 60 % 60,
            secondOfDay % 60)
        if nanos != 0 {
            if nanos % 1_000_000 == 0 {
                text += String(format: ".%03d", nanos / 1_000_000)
            } else if nanos % 1000 == 0 {
                text += String(format: ".%06d", nanos / 1000)
            } else {
                text += String(format: ".%09d", nanos)
            }
        }
        return text + "Z"
    }

    public var description: String { rfc3339 }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = Timestamp(rfc3339: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad timestamp"))
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rfc3339)
    }

    // Howard Hinnant's civil-calendar algorithms (proleptic Gregorian).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let mp = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}
