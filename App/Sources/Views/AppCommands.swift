import AppKit
import ChatModel
import SwiftUI

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button("Quit Thimble") { model.quitGuard.request() }
                .keyboardShortcut("q")
        }
        CommandGroup(after: .windowArrangement) {
            Button("Thimble") { showMainWindow() }
                .keyboardShortcut("1")
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { NSApplication.shared.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                .keyboardShortcut("x")
            Button("Copy") { NSApplication.shared.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                .keyboardShortcut("c")
            Button("Paste") {
                if !model.pasteIntoActiveComposer() {
                    NSApplication.shared.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
                }
            }
            .keyboardShortcut("v")
            Button("Select All") {
                NSApplication.shared.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("a")
        }
        CommandGroup(replacing: .newItem) {
            Button("New Message") {
                showMainWindow()
                model.openNewMessage()
            }
            .keyboardShortcut("n")
        }
        CommandGroup(replacing: .sidebar) {
            Button(model.showsSidebar ? "Hide Sidebar" : "Show Sidebar") {
                showMainWindow()
                withAnimation(.smooth(duration: 0.25)) { model.showsSidebar.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
        }
        CommandMenu("Go") {
            Button("Search Messages…") {
                showMainWindow()
                model.showsMessageSearch = true
            }
            .keyboardShortcut("f")
            .disabled(model.accounts.isEmpty)
            Button("Quick Switcher…") {
                showMainWindow()
                model.showsSwitcher = true
            }
            .keyboardShortcut("k")
            Divider()
            Button("All Accounts") { showAccount(nil) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            ForEach(Array(model.accounts.prefix(9).enumerated()), id: \.element.id) { index, info in
                Button(info.name) { showAccount(info.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
            }
        }
    }

    private func showAccount(_ id: AccountID?) {
        showMainWindow()
        model.accountFilter = id
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate()
    }
}
