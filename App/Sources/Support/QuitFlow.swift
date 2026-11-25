import AppKit

/// With unsaved drafts a quit is cancelled, the drafts saved, and the app quits again; main-actor work may not run in
/// `.terminateLater`'s modal loop. A save that fails or takes too long asks first.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: AppModel?
    static let saveDeadline: Duration = .seconds(5)

    /// The save still running for a quit; each one settles once.
    @MainActor private var attempt: UUID?
    @MainActor private var confirmed = false

    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, !confirmed, !model.draftsSettled, !Self.systemQuit else { return .terminateNow }
        guard attempt == nil else { return .terminateCancel }
        let id = UUID()
        attempt = id
        Task { @MainActor in self.finish(id, saved: await model.prepareToQuit()) }
        Task { @MainActor in
            try? await Task.sleep(for: Self.saveDeadline)
            self.finish(id, saved: false)
        }
        return .terminateCancel
    }

    /// Logout, restart and shutdown carry a quit reason; cancelling them would stop the whole system operation.
    @MainActor private static var systemQuit: Bool {
        NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }

    @MainActor private func finish(_ id: UUID, saved: Bool) {
        guard attempt == id else { return }
        attempt = nil
        if !saved {
            let alert = NSAlert()
            alert.messageText = "Some drafts couldn't be saved"
            alert.informativeText = "Quitting now loses their latest changes."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")
            guard alert.runModal() == .alertSecondButtonReturn else {
                Self.model?.cancelQuit()
                return
            }
        }
        confirmed = true
        NSApp.terminate(nil)
    }
}

/// ⌘Q quits only when pressed twice within `window`, like browsers; the first press shows a hint.
@MainActor @Observable
final class QuitGuard {
    static let window: Duration = .seconds(2)

    private(set) var hintVisible = false
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// Quit from the menu: a click, or ⌘Q with no main window to show the hint in, quits at once.
    func request() {
        guard let event = NSApp.currentEvent, event.type == .keyDown,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers?.lowercased() == "q", Self.mainWindowVisible
        else { return NSApp.terminate(nil) }
        guard !event.isARepeat else { return }
        if hintVisible {
            dismiss()
            return NSApp.terminate(nil)
        }
        hintVisible = true
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: "Press Command Q again to quit", .priority: NSAccessibilityPriorityLevel.high])
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.window)
            guard !Task.isCancelled else { return }
            self?.hintVisible = false
        }
    }

    private func dismiss() {
        hideTask?.cancel()
        hintVisible = false
    }

    private static var mainWindowVisible: Bool {
        NSApp.windows.contains {
            $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible && !$0.isMiniaturized
        }
    }
}
