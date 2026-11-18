import ChatModel
import ChatSync
import SwiftUI

private struct SnapshotModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Offscreen renders can't draw the sidebar's vibrancy, so snapshot mode swaps in a flat list style.
    var isSnapshotMode: Bool {
        get { self[SnapshotModeKey.self] }
        set { self[SnapshotModeKey.self] = newValue }
    }
}

enum AccountPalette {
    static let colors: [Color] = [
        Color(red: 0.20, green: 0.45, blue: 0.85), Color(red: 0.85, green: 0.45, blue: 0.10),
        Color(red: 0.12, green: 0.58, blue: 0.50), Color(red: 0.55, green: 0.32, blue: 0.80),
        Color(red: 0.78, green: 0.28, blue: 0.42), Color(red: 0.35, green: 0.50, blue: 0.62),
    ]

    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

struct AccountBadge: View {
    let info: AccountInfo?
    var size: CGFloat = 16

    var body: some View {
        let color = AccountPalette.color(info?.colorIndex ?? 0)
        Text(String((info?.name ?? "?").split(separator: " ").last?.prefix(1) ?? "?").uppercased())
            .font(.system(size: size * 0.6, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityLabel(info?.name ?? "Unknown account")
    }
}

struct AccountChip: View {
    let info: AccountInfo?
    var body: some View {
        HStack(spacing: 5) {
            AccountBadge(info: info, size: 14)
            Text(info?.name ?? "Unknown").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct UnreadPill: View {
    let count: Int
    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color.accentColor, in: Capsule())
            .accessibilityLabel("\(count) unread")
    }
}

struct SpaceIcon: View {
    let kind: SpaceKind

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(width: 14)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch kind {
        case .space: "number"
        case .directMessage: "person.fill"
        case .group: "person.2.fill"
        case .bot: "cpu"
        }
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 32

    var body: some View {
        let hue = Double(abs(name.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }) % 360) / 360
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hue: hue, saturation: 0.45, brightness: 0.62), in: Circle())
            .accessibilityHidden(true)
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }
}

enum TimeFormat {
    static func relative(_ time: Timestamp?, now: Date = Date()) -> String {
        guard let time else { return "" }
        let date = time.date
        let age = now.timeIntervalSince(date)
        let calendar = Calendar.current
        if age < 60 { return "now" }
        if calendar.isDateInToday(date) {
            if age < 3600 { return "\(Int(age / 60))m" }
            return date.formatted(.dateTime.hour().minute())
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if age < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    static func message(_ time: Timestamp, now: Date = Date()) -> String {
        let date = time.date
        let clock = date.formatted(.dateTime.hour().minute())
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return clock }
        if calendar.isDateInYesterday(date) { return "Yesterday \(clock)" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " " + clock
    }
}

extension AccountStatus {
    var warning: String? {
        switch self {
        case .needsLogin: "Needs sign-in"
        case .offline: "Offline"
        case .backingOff: "Retrying after errors"
        case .failed: "Failed"
        case .starting, .ok, .syncing, .closing: nil
        }
    }

    var label: String {
        switch self {
        case .starting: "Starting"
        case .ok: "OK"
        case .syncing: "Syncing"
        case .offline: "Offline"
        case .backingOff: "Backing off"
        case .needsLogin: "Needs sign-in"
        case .failed(let reason): "Failed (\(reason))"
        case .closing: "Signing out"
        }
    }
}
