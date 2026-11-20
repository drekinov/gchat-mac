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

/// A round Liquid Glass icon button the size of the toolbar's buttons, for buttons that live outside the toolbar:
/// the island's and the sheets' close buttons. Offscreen snapshots can't draw glass, so they get a flat circle.
struct GlassIconButton: View {
    static let size: CGFloat = 36
    let title: String
    let systemImage: String
    let help: String
    var role: ButtonRole?
    let action: () -> Void
    @Environment(\.isSnapshotMode) private var snapshotMode

    init(
        _ title: String, systemImage: String, help: String, role: ButtonRole? = nil, action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.help = help
        self.role = role
        self.action = action
    }

    var body: some View {
        let button = Button(role: role, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .imageScale(.large)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
        if snapshotMode {
            button.background(Color.primary.opacity(0.06), in: Circle())
        } else {
            button.glassEffect(.regular.interactive(), in: .circle)
        }
    }
}

/// The close button every sheet shows in its top-left corner, where a window's close button sits: an × in the same
/// glass as the window's buttons, with the close role so it reads as Close. Esc does the same.
struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        GlassIconButton("Close", systemImage: "xmark", help: "Close (Esc)", role: .close, action: action)
            .keyboardShortcut(.cancelAction)
    }
}

/// Account badge colours. None is close to the Slate accent, and each keeps white letters readable.
enum AccountPalette {
    static let colors: [Color] = [
        Color(red: 0x2E / 255, green: 0x7A / 255, blue: 0x4F / 255),  // green
        Color(red: 0xC0 / 255, green: 0x44 / 255, blue: 0x2C / 255),  // red
        Color(red: 0x8C / 255, green: 0x61 / 255, blue: 0x14 / 255),  // ochre
        Color(red: 0x7A / 255, green: 0x4F / 255, blue: 0x8C / 255),  // plum
        Color(red: 0x1F / 255, green: 0x7F / 255, blue: 0x86 / 255),  // teal
        Color(red: 0xA3 / 255, green: 0x40 / 255, blue: 0x5F / 255),  // rose
    ]

    static func color(_ index: Int) -> Color { colors[index % colors.count] }
}

struct AccountBadge: View {
    let info: AccountInfo?
    var size: CGFloat = 16

    var body: some View {
        let color = AccountPalette.color(info?.colorIndex ?? 0)
        Text(Self.letter(info?.name))
            .font(.system(size: size * 0.56, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: Circle())
            .accessibilityLabel(info.map { "\(RemoteText.title($0.name)) account" } ?? "Unknown account")
    }

    /// The first letter of the name's last word, so "Org B" and "Org C" stay apart. An account still named by
    /// its email uses the domain's first letter, so addresses at different organizations don't share a letter.
    static func letter(_ name: String?) -> String {
        let name = (name ?? "").trimmingCharacters(in: .whitespaces)
        let source =
            name.split(separator: "@").dropFirst().first.map(String.init)
            ?? name.split(separator: " ").last.map(String.init) ?? name
        return source.first(where: \.isLetter).map { String($0).uppercased() } ?? "?"
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
