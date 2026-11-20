import AppKit
import ChatModel
import ChatSync
import ServiceManagement
import SwiftUI
import UserNotifications

enum SidebarDensity: String, CaseIterable, Identifiable {
    case comfortable, compact

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"

    var id: String { rawValue }
    var title: String { self == .system ? "Auto" : rawValue.capitalized }

    @MainActor
    func apply() {
        NSApplication.shared.appearance =
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
    }

    @MainActor
    static func applyStored() {
        (UserDefaults.standard.string(forKey: key).flatMap(AppAppearance.init) ?? .system).apply()
    }
}

enum SettingsTab: String, CaseIterable {
    case general, accounts, notifications, appearance, developer
}

struct SettingsView: View {
    let model: AppModel
    @State private var tab: SettingsTab

    init(model: AppModel, initialTab: SettingsTab = .general) {
        self.model = model
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AccountsSettings(model: model)
                .tabItem { Label("Accounts", systemImage: "person.2") }
                .tag(SettingsTab.accounts)
            NotificationsSettings()
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(SettingsTab.notifications)
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(SettingsTab.appearance)
            #if DEBUG
                DeveloperSettings(model: model)
                    .tabItem { Label("Developer", systemImage: "hammer") }
                    .tag(SettingsTab.developer)
            #endif
        }
        .frame(width: 580, height: 440)
    }
}

struct AccountsSettings: View {
    let model: AppModel
    @State private var editing: AccountID?
    @State private var draft = ""
    @State private var removal: AccountInfo?

    private var accountOperationInProgress: Bool { model.isSigningIn || model.removingAccount != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.accounts.isEmpty {
                ContentUnavailableView("No accounts", systemImage: "person.crop.circle")
            } else {
                List(model.accounts) { info in
                    HStack(spacing: 10) {
                        AccountBadge(info: info, size: 22)
                        if editing == info.id {
                            TextField("Name", text: $draft, prompt: Text(info.email ?? "Name"))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 220)
                                .onSubmit { commit(info.id) }
                                .onExitCommand { editing = nil }
                        } else {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(RemoteText.title(info.name)).font(.body.weight(.medium))
                                if let email = info.email, email != info.name {
                                    Text(email).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
                        Circle().fill(statusColor(model.status(info.id))).frame(width: 8, height: 8)
                        Text(model.status(info.id).label).foregroundStyle(.secondary)
                        Button {
                            if editing == info.id {
                                commit(info.id)
                            } else {
                                draft = info.name == info.email ? "" : info.name
                                editing = info.id
                            }
                        } label: {
                            Image(systemName: editing == info.id ? "checkmark" : "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help(editing == info.id ? "Save name" : "Rename")
                        if model.live != nil {
                            Menu {
                                if !model.pendingRemoval.contains(info.id) {
                                    Button("Reconnect to Google…") { model.startReconnect(info) }
                                    Button("Reconnect using a client file…") {
                                        model.startReconnect(info, newClient: true)
                                    }
                                }
                                Button("Remove from this Mac…", role: .destructive) { removal = info }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .accessibilityLabel("Manage \(RemoteText.title(info.name))")
                            .disabled(accountOperationInProgress)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.bordered)
            }
            HStack {
                if model.isSigningIn {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the browser…")
                    Button("Cancel") { model.cancelSignIn() }
                } else {
                    Menu("+ Add account") {
                        if let project = model.savedClientProject {
                            Button("Using the saved client (\(project))") { model.startAddAccount() }
                        }
                        Button("Using a client file…") { model.startAddAccount(newClient: true) }
                    }
                    .fixedSize()
                    .disabled(model.live == nil || accountOperationInProgress)
                }
                if model.removingAccount != nil {
                    ProgressView().controlSize(.small)
                    Text("Removing account…")
                }
                Spacer()
                if let error = model.signInError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else if model.isFake {
                    Text("Sample data mode").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .confirmationDialog(
            "Remove this account from this Mac?",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            titleVisibility: .visible,
            presenting: removal
        ) { info in
            Button("Remove Account", role: .destructive) {
                Task { await model.removeAccount(info.id) }
            }
        } message: { info in
            Text(
                "This clears the local cache, drafts and queued messages for \(RemoteText.title(info.name)). "
                    + "Your Google Chat history stays in Google."
            )
        }
    }

    private func commit(_ id: AccountID) {
        model.rename(id, to: draft)
        editing = nil
    }

    private func statusColor(_ status: AccountStatus) -> Color {
        switch status {
        case .ok, .syncing: .green
        case .starting, .closing: .gray
        case .offline, .backingOff: .orange
        case .needsLogin, .failed: .red
        }
    }
}

struct GeneralSettings: View {
    @State private var status: SMAppService.Status = SMAppService.mainApp.status
    @State private var failure: String?
    @AppStorage(AppModel.historyLimitKey) private var historyLimit = 2000

    var body: some View {
        Form {
            Picker("Older messages per conversation", selection: $historyLimit) {
                ForEach(AppModel.historyLimits, id: \.self) { Text($0.formatted()).tag($0) }
            }
            Text(
                "Scrolling up loads earlier messages up to this many. Only the open conversation keeps them in memory."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Toggle("Launch at login", isOn: loginBinding)
            if status == .requiresApproval {
                Text("Approve Thimble in System Settings > General > Login Items.").font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            Text("Thimble keeps running in the menu bar, so notifications arrive while the window is closed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear { status = SMAppService.mainApp.status }
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { status == .enabled || status == .requiresApproval },
            set: { enable in
                do {
                    if enable { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    failure = nil
                } catch {
                    failure = "Couldn't change the login item. Try again from System Settings."
                }
                status = SMAppService.mainApp.status
            })
    }
}

struct NotificationsSettings: View {
    @AppStorage(NotificationCenterPoster.enabledKey) private var enabled = false
    @State private var authorization: UNAuthorizationStatus?
    @State private var denied = false
    @State private var testResult: String?
    private let statusOverride: UNAuthorizationStatus?

    init(statusOverride: UNAuthorizationStatus? = nil) {
        self.statusOverride = statusOverride
    }

    private let rows: [(setting: String, behaviour: String)] = [
        ("ALL", "Every message from others."),
        ("MAIN_CONVERSATIONS", "Top-level messages, plus replies in threads where I posted or was mentioned."),
        ("FOR_YOU", "@mentions of me or @all, plus all direct messages."),
        ("OFF / muted", "Nothing."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Enable notifications", isOn: enableBinding)
            if denied || (statusOverride ?? authorization) == .denied {
                HStack {
                    Text("Notifications are turned off for Thimble in System Settings.").font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
                        {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Button("Send Test Notification") {
                    Task { testResult = await NotificationCenterPoster.sendTest() }
                }
                if let testResult {
                    Text(testResult).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Text("What each space setting will notify for").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(rows, id: \.setting) { row in
                    GridRow {
                        Text(row.setting).font(.callout.monospaced())
                        Text(row.behaviour).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(
                "Never notified: silent messages, my own messages, the space that is open, and messages from before "
                    + "the first sync of an account."
            )
            .font(.callout)
            Text(
                "This approximates Google's behaviour. The Chat API does not expose per-thread follow state, so "
                    + "Thimble cannot match it exactly."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            authorization = await NotificationCenterPoster.authorizationStatus()
        }
    }

    private var enableBinding: Binding<Bool> {
        Binding(
            get: { enabled },
            set: { newValue in
                guard newValue else {
                    enabled = false
                    return
                }
                Task {
                    let status = await NotificationCenterPoster.authorizationStatus()
                    authorization = status
                    if status == .notDetermined {
                        denied = await !NotificationCenterPoster.requestAuthorization()
                    } else if status == .authorized || status == .provisional {
                        enabled = true
                        denied = false
                    } else {
                        enabled = false
                        denied = true
                    }
                    authorization = await NotificationCenterPoster.authorizationStatus()
                }
            })
    }
}

struct AppearanceSettings: View {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system
    @AppStorage("sidebarDensity") private var density = SidebarDensity.comfortable
    @AppStorage("inlineImagePreviews") private var inlinePreviews = false

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: appearance) { _, new in new.apply() }
            Text("Auto follows the system setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Show image previews inline", isOn: $inlinePreviews)
            Text("Off shows images and GIFs as small file chips; click one to preview it. On loads them in the thread.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Sidebar density", selection: $density) {
                ForEach(SidebarDensity.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Compact hides the last-message preview and tightens the rows. It applies immediately.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

#if DEBUG
    struct DeveloperSettings: View {
        let model: AppModel
        @AppStorage("fakeAccountCount") private var accountCount = AppModel.defaultFakeAccounts
        @AppStorage("fakeTrafficEnabled") private var trafficEnabled = true
        @AppStorage("fakeTrafficMin") private var trafficMin = 20.0
        @AppStorage("fakeTrafficMax") private var trafficMax = 40.0
        @AppStorage(NotificationCenterPoster.fakeKey) private var fakeNotifications = false

        var body: some View {
            Form {
                Section("Fake accounts") {
                    Stepper("Accounts: \(accountCount)", value: $accountCount, in: 1...FakeScript.maxAccounts)
                    Text(
                        "Applies on relaunch. A --fake-accounts N launch argument overrides this. "
                            + (model.isFake ? "Fake mode is active." : "Fake mode is not active in this launch.")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("Relaunch now") { Self.relaunch() }
                }
                Section("Background traffic") {
                    Toggle("Post new messages", isOn: $trafficEnabled)
                    Stepper("Shortest gap: \(Int(trafficMin)) s", value: $trafficMin, in: 1...300, step: 5)
                    Stepper("Longest gap: \(Int(trafficMax)) s", value: $trafficMax, in: 1...300, step: 5)
                    Text("Takes effect on the next message.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Fake notifications", isOn: $fakeNotifications)
                    Text("Posts real system notifications for fake traffic. Needs Notifications enabled.").font(
                        .caption
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }

        private static func relaunch() {
            var arguments = Array(CommandLine.arguments.dropFirst())
            if let index = arguments.firstIndex(of: "--fake-accounts") {
                arguments.removeSubrange(index..<min(index + 2, arguments.count))
            }
            if !arguments.contains("--fake") { arguments.append("--fake") }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = arguments
            let url = Bundle.main.bundleURL
            Task {
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                NSApplication.shared.terminate(nil)
            }
        }
    }
#endif
