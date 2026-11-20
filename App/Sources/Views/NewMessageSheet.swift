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
        /// Explains the email route while a name is typed; not selectable.
        case hint(String)

        var id: String {
            switch self {
            case .header(let title): "h-\(title)"
            case .person(let contact): "p-\(contact.id)"
            case .email(let contact): "e-\(contact.id)"
            case .hint: "hint"
            }
        }

        var contact: Contact? {
            switch self {
            case .header, .hint: nil
            case .person(let contact), .email(let contact): contact
            }
        }
    }

    var body: some View {
        let entries = entries()
        let selectable = entries.compactMap(\.contact)
        VStack(spacing: 0) {
            header
            searchField(selectable)
            list(entries, selectable)
            if let errorText {
                Divider()
                Text(errorText).font(.callout).foregroundStyle(Theme.error).padding(12)
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
        let info = accountID.flatMap { model.info($0) }
        return HStack(spacing: 10) {
            SheetCloseButton(action: close)
            Text("New message").font(.title3.weight(.semibold))
            Spacer()
            Menu {
                Picker("From", selection: $accountID) {
                    ForEach(model.accounts) { account in
                        Text(RemoteText.title(account.name)).tag(Optional(account.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 6) {
                    Text("From").foregroundStyle(.secondary)
                    AccountBadge(info: info, size: 14)
                    Text(RemoteText.title(info?.name ?? "Account"))
                }
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Account the chat starts from")
            .accessibilityLabel("From \(RemoteText.title(info?.name ?? "no account"))")
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func searchField(_ selectable: [Contact]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
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
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private func list(_ entries: [Entry], _ selectable: [Contact]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if selectable.isEmpty {
                        Text(query.isEmpty ? "No contacts yet. Type a name or an email address." : "No matches")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    }
                    ForEach(entries) { entry in
                        switch entry {
                        case .header(let title):
                            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                        case .person(let contact):
                            row(contact, label: nil, highlighted: selectable[safe: highlight]?.id == contact.id)
                                .id(entry.id)
                        case .email(let contact):
                            row(
                                contact, label: "Message \(RemoteText.title(contact.email ?? ""))",
                                highlighted: selectable[safe: highlight]?.id == contact.id
                            )
                            .id(entry.id)
                        case .hint(let text):
                            hintRow(text)
                        }
                    }
                }
                .padding(.horizontal, 6)
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
                envelope
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label ?? RemoteText.title(contact.displayName)).fontWeight(.medium).lineLimit(1)
                if label == nil, let email = contact.email, !email.isEmpty {
                    Text(RemoteText.title(email)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if starting == contact.id {
                ProgressView().controlSize(.small)
            } else if contact.directMessage != nil {
                Text("DM")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 4))
                    .help("You already have a direct message with this person")
                    .accessibilityLabel("Direct message")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(highlighted ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onTapGesture { start(contact) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
    }

    private func hintRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            envelope
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .padding(.top, 4)
    }

    private var envelope: some View {
        Image(systemName: "envelope")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 30, height: 30)
            .background(.fill.tertiary, in: Circle())
            .accessibilityHidden(true)
    }

    // MARK: Content

    private func entries() -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let filtered = local.filter { contact in
            needle.isEmpty || contact.displayName.localizedCaseInsensitiveContains(needle)
                || (contact.email?.localizedCaseInsensitiveContains(needle) ?? false)
        }
        // People with a DM first, then everyone else from shared spaces.
        let people = filtered.filter { $0.directMessage != nil } + filtered.filter { $0.directMessage == nil }
        var result: [Entry] = []
        if !people.isEmpty { result += [.header("People you chat with")] + people.map(Entry.person) }

        let known = Set(local.compactMap(\.user))
        let fresh = directory.filter { $0.user.map { !known.contains($0) } ?? true }
        if let accountID, model.directoryAvailable(for: accountID), !needle.isEmpty {
            if !fresh.isEmpty { result += [.header("Directory")] + fresh.map(Entry.person) }
        }
        if Self.isValidEmail(needle) {
            let lower = needle.lowercased()
            let listed = (local + fresh).contains { $0.email?.lowercased() == lower }
            if !listed { result += [.header("Email address"), .email(Contact.typed(email: needle))] }
        } else if !needle.isEmpty {
            result.append(.hint("Type a full email address to message anyone in the directory."))
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
