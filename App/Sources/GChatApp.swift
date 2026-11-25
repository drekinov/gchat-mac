import AppKit
import SwiftUI

struct GChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    private let responder: NotificationResponder

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        AppDelegate.model = model
        responder = NotificationResponder.install(model: model)
        AppAppearance.applyStored()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { model.shutdown() } }
    }

    var body: some Scene {
        Window("Thimble", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1180, height: 760)
        .restorationBehavior(.disabled)
        .commands {
            AppCommands(model: model)
            #if DEBUG
                DebugCommands()
            #endif
        }

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)

        #if DEBUG
            Window("Footprint", id: "footprint") {
                FootprintPanel(model: model)
            }
            .defaultSize(width: 380, height: 320)
        #endif
    }
}
