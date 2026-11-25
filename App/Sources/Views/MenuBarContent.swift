import AppKit
import SwiftUI

struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let unread = model.unreadTotal
        HStack(spacing: 3) {
            Image(systemName: unread > 0 ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
            if unread > 0 { Text("\(unread)") }
        }
        .onChange(of: model.openWindowRequest) { openWindow(id: "main") }
        .onChange(of: unread, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        }
        .task {
            if BenchConfig(arguments: CommandLine.arguments) != nil || CommandLine.arguments.contains("--repro-thread")
            {
                openWindow(id: "main")
            }
        }
    }
}

struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let unread = model.unreadTotal
        let recent = Array(model.recentUnread.prefix(5))
        Text(unread == 0 ? "No unread messages" : "\(unread) unread")
        ForEach(recent) { entry in
            Button(label(entry)) {
                model.select(entry.id)
                showWindow()
            }
        }
        Divider()
        Button("Open Thimble") { showWindow() }
        Divider()
        Button("Quit Thimble") { NSApplication.shared.terminate(nil) }
    }

    private func label(_ entry: InboxEntry) -> String {
        let account = model.info(entry.account)?.name ?? ""
        return "\(RemoteText.title(entry.summary.title)) (\(entry.unread)) - \(account)"
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate()
    }
}
