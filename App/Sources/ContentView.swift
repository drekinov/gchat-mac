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
                MainLayout(model: model)
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .overlay(alignment: .top) {
            if model.quitGuard.hintVisible { QuitHint().padding(.top, 14) }
        }
        .animation(.easeOut(duration: 0.2), value: model.quitGuard.hintVisible)
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

/// The sidebar as an inset island beside the conversation. Not a split view: the system one draws a glass edge and
/// shadow between the columns that can't be turned off.
struct MainLayout: View {
    @Bindable var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            // The transparent toolbar strip puts the traffic lights in the island's corner and holds the
            // conversation's buttons. Offscreen snapshots have no toolbar, so they get the same strip.
            let top = proxy.safeAreaInsets.top > 0 ? proxy.safeAreaInsets.top : 52
            HStack(spacing: 0) {
                if model.showsSidebar {
                    island(top: top)
                        .padding(.horizontal, Island.gap)
                        .padding(.top, Island.top)
                        .padding(.bottom, Island.gap)
                        .frame(width: Island.width)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                detail(top: top)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .environment(\.titlebarHeight, top)
            .ignoresSafeArea(.container, edges: .top)
        }
        // One surface for the whole window: the island sits on it, and so does the conversation.
        .background(Color(nsColor: .textBackgroundColor))
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar(removing: .title)
        .toolbar {
            // Keeps the toolbar, and with it the traffic lights' place, when no conversation is open, and keeps
            // the conversation's buttons at the trailing edge.
            ToolbarSpacer(.flexible)
            if !model.showsSidebar {
                ToolbarItem(placement: .navigation) {
                    Button(action: toggleSidebar) {
                        Label("Show sidebar", systemImage: "sidebar.left")
                    }
                    .help("Show the sidebar (Control-Cmd-S)")
                }
            }
        }
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

    /// The sidebar panel. The traffic lights sit in its top left; its two buttons sit in its top right, centred
    /// on the same line and the same size as the toolbar's buttons.
    private func island(top: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Island.buttonSpacing) {
                Spacer(minLength: 0)
                GlassIconButton("New message", systemImage: "square.and.pencil", help: "New message (Cmd-N)") {
                    model.openNewMessage()
                }
                GlassIconButton("Hide sidebar", systemImage: "sidebar.left", help: "Hide the sidebar (Control-Cmd-S)") {
                    toggleSidebar()
                }
            }
            .padding(.trailing, Island.buttonInset)
            .padding(.top, top / 2 - GlassIconButton.size / 2 - Island.top)
            .frame(height: top - Island.top, alignment: .top)
            .background { WindowDragArea() }
            SidebarView(model: model)
        }
        .background(Theme.island, in: Island.shape)
        .overlay(Island.shape.strokeBorder(Theme.islandEdge))
        .clipShape(Island.shape)
    }

    @ViewBuilder
    private func detail(top: CGFloat) -> some View {
        if let key = model.selection {
            SpaceView(model: model, key: key).id(key)
        } else {
            VStack(spacing: 0) {
                WindowDragArea().frame(height: top)
                ContentUnavailableView("Select a conversation", systemImage: "bubble.left.and.bubble.right")
                    .frame(maxHeight: .infinity)
            }
        }
    }

    private func toggleSidebar() {
        withAnimation(.smooth(duration: 0.25)) { model.showsSidebar.toggle() }
    }
}

private enum Island {
    static let width: CGFloat = 330
    /// Space between the island and the window's left and bottom edges, and between it and the conversation.
    static let gap: CGFloat = 8
    /// Space above the island. Smaller than the others so the toolbar-sized buttons, centred on the traffic
    /// lights, still have room inside it.
    static let top: CGFloat = 4
    /// From the island's right edge to its buttons, the same as the room above them.
    static let buttonInset: CGFloat = 4
    /// The toolbar's own gap between separate buttons.
    static let buttonSpacing: CGFloat = 8
    static let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
}

extension EnvironmentValues {
    /// The height of the window's toolbar strip, where the conversation's title sits.
    @Entry var titlebarHeight: CGFloat = 52
}

/// Empty header space that behaves like a title bar: drag it to move the window, double-click it to do what the
/// title bar setting in System Settings says (zoom by default).
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .simultaneousGesture(TapGesture(count: 2).onEnded { Self.titleBarDoubleClick() })
            .allowsWindowActivationEvents(true)
    }

    @MainActor
    static func titleBarDoubleClick() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

/// Shown after the first ⌘Q.
struct QuitHint: View {
    var body: some View {
        Text("Press ⌘Q again to quit")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .transition(.move(edge: .top).combined(with: .opacity))
            .allowsHitTesting(false)
    }
}
