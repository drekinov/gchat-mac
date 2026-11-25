import AppKit
import ChatModel
import ChatSync
import GoogleChat
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

    /// One size for every tab, so the window doesn't jump while switching.
    static let size = NSSize(width: 620, height: 480)

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
                .tabItem { Label("Appearance", systemImage: "circle.lefthalf.filled") }
                .tag(SettingsTab.appearance)
            #if DEBUG
                DeveloperSettings(model: model)
                    .tabItem { Label("Developer", systemImage: "hammer") }
                    .tag(SettingsTab.developer)
            #endif
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}

struct AccountsSettings: View {
    let model: AppModel
    @State private var editing: AccountID?
    @State private var draft = ""
    @State private var removal: AccountInfo?

    private var accountOperationInProgress: Bool { model.isSigningIn || model.removingAccount != nil }

    var body: some View {
        Form {
            Section {
                if model.accounts.isEmpty {
                    Label("No accounts yet", systemImage: "person.crop.circle").foregroundStyle(.secondary)
                }
                ForEach(model.accounts) { info in
                    VStack(alignment: .leading, spacing: 6) {
                        row(info)
                        LiveNotificationsSettings(model: model, info: info)
                            .padding(.leading, 40)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 12) {
                    addAccountBar
                    Text(
                        "Each account has a letter and colour. They mark its chats in the sidebar when you show all "
                            + "accounts, and the account you send from."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
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

    private func row(_ info: AccountInfo) -> some View {
        let status = model.status(info.id)
        let canReconnect = model.live != nil && !model.pendingRemoval.contains(info.id)
        let isEditing = editing == info.id
        return HStack(spacing: 12) {
            AccountBadge(info: info, size: 28)
            if isEditing {
                TextField("Name", text: $draft, prompt: Text(info.email ?? "Name"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .onSubmit { commit(info.id) }
                    .onExitCommand { editing = nil }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(RemoteText.title(info.name)).fontWeight(.medium).lineLimit(1)
                    if let email = info.email, email != info.name {
                        Text(RemoteText.title(email)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Circle().fill(status.dotColor).frame(width: 8, height: 8)
                Text(status.settingsLabel).font(.callout).foregroundStyle(status.labelColor).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            if status == .needsLogin, canReconnect {
                Button("Sign in again…") { model.startReconnect(info) }
                    .buttonStyle(.borderedProminent)
                    .disabled(accountOperationInProgress)
            }
            Button {
                if isEditing {
                    commit(info.id)
                } else {
                    draft = info.name == info.email ? "" : info.name
                    editing = info.id
                }
            } label: {
                Image(systemName: isEditing ? "checkmark" : "pencil").frame(width: 14)
            }
            .help(isEditing ? "Save name" : "Rename")
            .accessibilityLabel(isEditing ? "Save name" : "Rename \(RemoteText.title(info.name))")
            if model.live != nil {
                Menu {
                    if canReconnect {
                        Button("Reconnect to Google…") { model.startReconnect(info) }
                        Button("Reconnect using a client file…") {
                            model.startReconnect(info, newClient: true)
                        }
                    }
                    Button("Remove from this Mac…", role: .destructive) { removal = info }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("Manage \(RemoteText.title(info.name))")
                .disabled(accountOperationInProgress)
            }
        }
        .padding(.vertical, 2)
    }

    private var addAccountBar: some View {
        HStack(spacing: 8) {
            if model.isSigningIn {
                ProgressView().controlSize(.small)
                Text("Waiting for the browser…")
                Button("Cancel") { model.cancelSignIn() }
            } else {
                Menu {
                    if let project = model.savedClientProject {
                        Button("Using the saved client (\(project))") { model.startAddAccount() }
                    }
                    Button("Using a client file…") { model.startAddAccount(newClient: true) }
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .fixedSize()
                .disabled(model.live == nil || accountOperationInProgress)
            }
            if model.removingAccount != nil {
                ProgressView().controlSize(.small)
                Text("Removing account…")
            }
            Spacer(minLength: 8)
            if let error = model.signInError {
                Text(error).font(.caption).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true)
            } else if model.isFake {
                Text("Sample data mode").font(.caption).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
    }

    private func commit(_ id: AccountID) {
        model.rename(id, to: draft)
        editing = nil
    }
}

extension AccountStatus {
    /// Plain words for the Accounts tab; the sidebar and debug panel keep their shorter labels.
    fileprivate var settingsLabel: String {
        switch self {
        case .starting: "Connecting…"
        case .ok: "Up to date"
        case .syncing: "Syncing…"
        case .offline: "Offline"
        case .backingOff: "Retrying soon"
        case .needsLogin: "Needs sign-in"
        case .failed(let reason): "Not working (\(reason))"
        case .closing: "Signing out…"
        }
    }

    fileprivate var dotColor: Color {
        switch self {
        case .ok, .syncing: Self.okColor
        case .starting, .closing: Color.secondary
        case .offline, .backingOff, .needsLogin: Theme.warning
        case .failed: Theme.error
        }
    }

    fileprivate var labelColor: Color {
        switch self {
        case .needsLogin: Theme.warning
        case .failed: Theme.error
        default: Color.secondary
        }
    }

    private static let okColor = Theme.dynamic(light: 0x2E_7A4F, dark: 0x7C_C49A)
}

/// This Mac's Workspace Events channel for one account. Off stops pulling and renewing here; nothing is deleted.
struct LiveNotificationsSettings: View {
    let model: AppModel
    let info: AccountInfo
    @State private var expanded = false
    @State private var draft = ""

    private var settings: EventSettings { model.eventSettings[info.id] ?? EventSettings() }
    private var status: EventChannelStatus { model.eventStatus[info.id] ?? .off }
    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var draftIsValid: Bool { trimmed.isEmpty || PubSubSubscriptionPath(trimmed) != nil }
    private var draftChanged: Bool { trimmed != (settings.subscriptionPath ?? "") }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField(
                        "Subscription", text: $draft, prompt: Text("projects/PROJECT/subscriptions/NAME")
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .labelsHidden()
                    .onSubmit(save)
                    Button("Save", action: save).disabled(!draftIsValid || !draftChanged)
                }
                if !draftIsValid {
                    Text("Expected projects/PROJECT/subscriptions/NAME.").font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Toggle("On for this Mac", isOn: enabledBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Spacer()
                    if model.live != nil {
                        Button("Grant Access…") { model.startReconnect(info, liveNotifications: true) }
                            .disabled(model.isSigningIn || model.removingAccount != nil)
                            .help("Sign in again to allow Pub/Sub, which live notifications need.")
                    }
                }
                Text(
                    "Run scripts/events-setup.sh once per account and Mac, paste the subscription path it prints, "
                        + "then grant access. Off affects only this Mac and deletes nothing."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if let error = model.eventSettingsError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Text("Live notifications")
                Text(status.label).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .onAppear { draft = settings.subscriptionPath ?? "" }
    }

    private func save() {
        guard draftIsValid, draftChanged else { return }
        let path = trimmed.isEmpty ? nil : trimmed
        let enabled = settings.enabled
        Task { await model.setEventSettings(info.id, EventSettings(subscriptionPath: path, enabled: enabled)) }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.enabled },
            set: { enabled in
                let path = settings.subscriptionPath
                Task { await model.setEventSettings(info.id, EventSettings(subscriptionPath: path, enabled: enabled)) }
            })
    }
}

struct GeneralSettings: View {
    @State private var status: SMAppService.Status = SMAppService.mainApp.status
    @State private var failure: String?
    @AppStorage(AppModel.historyLimitKey) private var historyLimit = 2000

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: loginBinding)
                if let failure {
                    Text(failure).foregroundStyle(Theme.error)
                }
            } footer: {
                Text("Thimble keeps running in the menu bar, so notifications arrive while the window is closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if status == .requiresApproval {
                Section {
                    WarningRow(
                        title: "macOS needs your approval to open Thimble at login.",
                        detail: "Approve Thimble in System Settings, General, Login Items."
                    ) {
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
            }
            Section {
                Picker(selection: $historyLimit) {
                    ForEach(AppModel.historyLimits, id: \.self) { Text($0.formatted()).tag($0) }
                } label: {
                    Text("Older messages per conversation")
                    Text(
                        "Scrolling up loads earlier messages up to this many. Only the open conversation keeps "
                            + "them in memory.")
                }
            }
        }
        .formStyle(.grouped)
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

/// A form row that needs the person to act somewhere else: warning sign, explanation, one button.
private struct WarningRow<Action: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action
        }
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

    /// Google's space settings ALL, MAIN_CONVERSATIONS, FOR_YOU and OFF (or muted), in plain words.
    private let rows: [(setting: String, behaviour: String)] = [
        ("All messages", "Every message from others."),
        ("Main conversations", "Top-level messages, plus replies in threads where you posted or were mentioned."),
        ("For you", "@mentions of you or @all, plus all direct messages."),
        ("Off or muted", "Nothing."),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Enable notifications", isOn: enableBinding)
                if denied || (statusOverride ?? authorization) == .denied {
                    WarningRow(title: "Notifications are turned off for Thimble in System Settings.") {
                        Button("Open System Settings") {
                            if let url = URL(
                                string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
                            {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Send a test notification")
                        if let testResult {
                            Text(testResult).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    Button("Send Test") {
                        Task { testResult = await NotificationCenterPoster.sendTest() }
                    }
                }
            }
            Section {
                ForEach(rows, id: \.setting) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.setting).fontWeight(.medium).frame(width: 140, alignment: .leading)
                        Text(row.behaviour).font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("What each space setting notifies you about")
            } footer: {
                Text(
                    "You're never notified about silent messages, your own messages, the conversation you have open, "
                        + "or messages from before an account's first sync. This follows Google's rules as closely as "
                        + "the Chat API allows; it can't see which threads you follow."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
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
            Section {
                Picker(selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Appearance")
                    Text("Auto follows the system setting.")
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, new in new.apply() }
                Picker(selection: $density) {
                    ForEach(SidebarDensity.allCases) { Text($0.title).tag($0) }
                } label: {
                    Text("Sidebar")
                    Text("Compact hides the message preview and tightens the rows.")
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle(isOn: $inlinePreviews) {
                    Text("Show images in the conversation")
                    Text("Off shows images and GIFs as small file chips. Click one to preview it.")
                }
            }
        }
        .formStyle(.grouped)
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
                Section {
                    Stepper(value: $accountCount, in: 1...FakeScript.maxAccounts) {
                        Text("Accounts: \(accountCount)")
                        Text(
                            "Applies on relaunch. A --fake-accounts N launch argument overrides this. "
                                + (model.isFake ? "Sample data is active." : "Sample data isn't active in this launch.")
                        )
                    }
                    LabeledContent("Relaunch with sample data") {
                        Button("Relaunch Now") { Self.relaunch() }
                    }
                } header: {
                    Text("Sample data")
                }
                Section {
                    Toggle(isOn: $trafficEnabled) {
                        Text("Post new messages")
                        Text("Takes effect on the next message.")
                    }
                    Stepper("Shortest gap: \(Int(trafficMin)) s", value: $trafficMin, in: 1...300, step: 5)
                    Stepper("Longest gap: \(Int(trafficMax)) s", value: $trafficMax, in: 1...300, step: 5)
                    Toggle(isOn: $fakeNotifications) {
                        Text("Fake notifications")
                        Text("Posts real system notifications for sample traffic. Needs Notifications enabled.")
                    }
                } header: {
                    Text("Background traffic")
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
