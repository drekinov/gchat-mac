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
                            model.showsMessageSearch = true
                        } label: {
                            Label("Search messages", systemImage: "magnifyingglass")
                        }
                        .help("Search messages (Cmd-F)")
                    }
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
                    ImagePreviewSheet(target: target) { model.preview = nil }
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

struct SignInView: View {
    let model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Add a Google account", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text(
                "Sign-in opens in your browser. Pick the account that belongs to the client's organization and leave "
                    + "every permission ticked.")
        } actions: {
            VStack(spacing: 10) {
                if model.isSigningIn {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the browser…")
                        Button("Cancel") { model.cancelSignIn() }
                    }
                } else {
                    if let project = model.savedClientProject {
                        Button("Sign in with Google") { model.startAddAccount() }
                            .buttonStyle(.borderedProminent)
                        Text("Client: \(project)").font(.caption).foregroundStyle(.secondary)
                    }
                    if model.savedClientProject == nil {
                        Button("Choose client file and sign in…") { model.startAddAccount(newClient: true) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Use another client file…") { model.startAddAccount(newClient: true) }
                    }
                }
                if let error = model.signInError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
        }
    }
}
