import ChatModel
import ChatSync
import SwiftUI

struct NewMessageSheet: View {
    let model: AppModel
    var onClose: (() -> Void)?
    var snapshotQuery = ""

    @Environment(\.dismiss) private var dismiss
    @State private var accountID: AccountID?
    @State private var query: String
    @State private var local: [Contact] = []
    @State private var directory: [Contact] = []
    @State private var searching = false
    @State private var directoryTask: Task<Void, Never>?
    @State private var highlight = 0
    @State private var starting: String?
    @State private var errorText: String?
    @FocusState private var focused: Bool

    init(model: AppModel, onClose: (() -> Void)? = nil, snapshotQuery: String = "") {
        self.model = model
        self.onClose = onClose
        self.snapshotQuery = snapshotQuery
        _query = State(initialValue: snapshotQuery)
    }

    private enum Entry: Identifiable {
        case header(String)
        case person(Contact)
        case email(Contact)

        var id: String {
            switch self {
            case .header(let title): "h-\(title)"
            case .person(let contact): "p-\(contact.id)"
            case .email(let contact): "e-\(contact.id)"
            }
        }

        var contact: Contact? {
            switch self {
            case .header: nil
            case .person(let contact), .email(let contact): contact
            }
        }
    }

    var body: some View {
        let entries = entries()
        let selectable = entries.compactMap(\.contact)
        VStack(spacing: 0) {
            header
            Divider()
            searchField(selectable)
            Divider()
            list(entries, selectable)
            if let errorText {
                Divider()
                Text(errorText).font(.callout).foregroundStyle(.red).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 480, height: 560)
        .onExitCommand(perform: close)
        .task {
            if accountID == nil { accountID = model.newMessageAccount ?? model.accounts.first?.id }
            focused = true
        }
        .task(id: accountID) {
            guard let accountID else { return }
            model.refreshContacts(for: accountID)
            local = await model.contacts(for: accountID)
            directory = []
            if !query.isEmpty { scheduleDirectorySearch() }
        }
        .onChange(of: model.snapshots[accountID ?? AccountID()]?.revision) {
            guard let accountID else { return }
            Task { local = await model.contacts(for: accountID) }
        }
        .onChange(of: query) {
            highlight = 0
            errorText = nil
            scheduleDirectorySearch()
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 10) {
            Text("New message").font(.title3.weight(.semibold))
            Spacer()
            Menu {
                ForEach(model.accounts) { info in
                    Button(RemoteText.title(info.name)) { accountID = info.id }
                }
            } label: {
                HStack(spacing: 6) {
                    AccountBadge(info: accountID.flatMap { model.info($0) }, size: 16)
                    Text(RemoteText.title(accountID.flatMap { model.info($0)?.name } ?? "Account"))
                }
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Account the chat starts from")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func searchField(_ selectable: [Contact]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Name or email", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit { start(selectable[safe: highlight]) }
                .onKeyPress(.downArrow) {
                    highlight = min(highlight + 1, max(selectable.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    highlight = max(highlight - 1, 0)
                    return .handled
                }
            if searching { ProgressView().controlSize(.small) }
        }
        .padding(12)
    }

    private func list(_ entries: [Entry], _ selectable: [Contact]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        switch entry {
                        case .header(let title):
                            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                        case .person(let contact):
                            row(contact, label: nil, highlighted: selectable[safe: highlight]?.id == contact.id)
                                .id(entry.id)
                        case .email(let contact):
                            row(
                                contact, label: "Message \(RemoteText.title(contact.email ?? ""))",
                                highlighted: selectable[safe: highlight]?.id == contact.id
                            )
                            .id(entry.id)
                        }
                    }
                    if selectable.isEmpty {
                        Text(query.isEmpty ? "No contacts yet. Type a name or an email address." : "No matches")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: highlight) {
                if let contact = selectable[safe: highlight] {
                    proxy.scrollTo(entries.first { $0.contact?.id == contact.id }?.id)
                }
            }
        }
    }

    private func row(_ contact: Contact, label: String?, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            if label == nil {
                Avatar(name: RemoteText.title(contact.displayName), size: 30)
            } else {
                Image(systemName: "envelope.fill").foregroundStyle(.secondary).frame(width: 30, height: 30)
                    .background(Color.secondary.opacity(0.15), in: Circle())
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(label ?? RemoteText.title(contact.displayName)).lineLimit(1)
                if label == nil, let email = contact.email, !email.isEmpty {
                    Text(RemoteText.title(email)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if starting == contact.id {
                ProgressView().controlSize(.small)
            } else if contact.directMessage != nil {
                Text("DM").font(.system(size: 10, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.2), in: Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(highlighted ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { start(contact) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Content

    private func entries() -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let filtered = local.filter { contact in
            needle.isEmpty || contact.displayName.localizedCaseInsensitiveContains(needle)
                || (contact.email?.localizedCaseInsensitiveContains(needle) ?? false)
        }
        let recent = filtered.filter { $0.directMessage != nil }
        let others = filtered.filter { $0.directMessage == nil }
        var result: [Entry] = []
        if !recent.isEmpty { result += [.header("Recent DMs")] + recent.map(Entry.person) }
        if !others.isEmpty { result += [.header("People from your chats")] + others.map(Entry.person) }

        let known = Set(local.compactMap(\.user))
        let fresh = directory.filter { $0.user.map { !known.contains($0) } ?? true }
        if let accountID, model.directoryAvailable(for: accountID), !needle.isEmpty {
            if !fresh.isEmpty { result += [.header("Directory")] + fresh.map(Entry.person) }
        }
        if Self.isValidEmail(needle) {
            let lower = needle.lowercased()
            let listed = (local + fresh).contains { $0.email?.lowercased() == lower }
            if !listed { result += [.header("Email address"), .email(Contact.typed(email: needle))] }
        }
        return result
    }

    static func isValidEmail(_ text: String) -> Bool {
        text.wholeMatch(of: /[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)+/) != nil
    }

    // MARK: Actions

    private func scheduleDirectorySearch() {
        directoryTask?.cancel()
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard let accountID, !needle.isEmpty, model.directoryAvailable(for: accountID) else {
            directory = []
            searching = false
            return
        }
        searching = true
        directoryTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await model.searchDirectory(needle, for: accountID)
            guard !Task.isCancelled else { return }
            directory = found
            searching = false
        }
    }

    private func start(_ contact: Contact?) {
        guard let contact, let accountID, starting == nil else { return }
        starting = contact.id
        errorText = nil
        Task {
            let failure = await model.startDirectMessage(contact, account: accountID)
            starting = nil
            if let failure {
                errorText = failure
            } else {
                close()
            }
        }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
}
