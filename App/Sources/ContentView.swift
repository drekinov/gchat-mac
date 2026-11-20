import AppKit
import ChatModel
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.phase {
            case .idle, .starting:
                ProgressView("Starting…")
            case .needsLogin:
                SignInView(model: model)
            case .running:
                RootSplitView(model: model)
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .task {
            await model.boot()
            if let bench = BenchConfig(arguments: CommandLine.arguments) {
                await BenchRunner(model: model, config: bench).run()
            } else if model.isFake, CommandLine.arguments.contains("--repro-thread") {
                await ThreadRepro(model: model).run()
            }
        }
        .onChange(of: activeState, initial: true) { model.windowIsKey = activeState == .key }
        .onDisappear { model.windowIsKey = false }
        .onChange(of: scenePhase) { model.setAppActive(scenePhase == .active) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.setAppActive(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.setAppActive(false)
        }
    }
}

struct RootSplitView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 270, ideal: 330, max: 440)
                .toolbar {
                    ToolbarItem {
                        Button {
                            model.openNewMessage()
                        } label: {
                            Label("New message", systemImage: "square.and.pencil")
                        }
                        .help("New message (Cmd-N)")
                    }
                }
        } detail: {
            // Threads open in place inside the conversation, so the detail is a single column.
            detail
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .toolbar(removing: .title)
                .sheet(item: $model.preview) { target in
                    ImagePreviewSheet(target: target, onShowInChat: { model.showInConversation($0) }) {
                        model.preview = nil
                    }
                }
                .sheet(isPresented: $model.showsNewMessage) {
                    NewMessageSheet(model: model)
                }
                .sheet(isPresented: $model.showsSwitcher) {
                    QuickSwitcher(model: model) { model.showsSwitcher = false }
                }
                .sheet(isPresented: $model.showsMessageSearch) {
                    MessageSearchSheet(model: model)
                }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let key = model.selection {
            SpaceView(model: model, key: key).id(key)
        } else {
            ContentUnavailableView("Select a conversation", systemImage: "bubble.left.and.bubble.right")
        }
    }
}
