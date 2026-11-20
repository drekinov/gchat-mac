import ChatModel
import ChatSync
import GoogleChat
import SwiftUI

private struct MessageHit: Hashable {
    let account: AccountID
    let message: Message

    var key: SpaceKey { SpaceKey(account: account, space: message.space) }
}

struct MessageSearchSheet: View {
    let model: AppModel
    @State private var text = ""
    @State private var query = ""
    @State private var submission = UUID()
    @State private var account: AccountID?
    @State private var selected: MessageHit?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    static let size = NSSize(width: 800, height: 540)

    init(model: AppModel, initialQuery: String = "") {
        self.model = model
        _account = State(initialValue: model.accountFilter)
        _text = State(initialValue: initialQuery)
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search messages").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.leading, 20)
            .padding(.trailing, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            searchBar
                .padding(.leading, 20)
                .padding(.trailing, 16)
                .padding(.bottom, 12)
            Divider()
            // The empty states fill the space below the search field, so the field stays at the top of the sheet.
            if query.isEmpty {
                ContentUnavailableView("Search your messages", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if query.unicodeScalars.count > 1000 {
                ContentUnavailableView("Use 1,000 characters or fewer", systemImage: "text.magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    results.frame(width: 330)
                    Divider()
                    Group {
                        if let selected {
                            SearchMessageDetail(model: model, hit: selected).id(selected)
                        } else {
                            ContentUnavailableView("Select a result", systemImage: "text.bubble")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = true }
        .onChange(of: model.accounts.map(\.id)) {
            selected = nil
            if let account, model.info(account) == nil { self.account = nil }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search Google Chat", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(submit)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
            accountMenu
            Button(action: submit) {
                Text("Search").fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var accountMenu: some View {
        let info = account.flatMap { model.info($0) }
        return Menu {
            Picker("Account", selection: $account) {
                Text("All accounts").tag(nil as AccountID?)
                ForEach(model.accounts) { info in
                    Text(RemoteText.title(info.name)).tag(Optional(info.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                if let info {
                    AccountBadge(info: info, size: 14)
                    Text(RemoteText.title(info.name))
                } else {
                    HStack(spacing: -3) {
                        ForEach(model.accounts.prefix(4)) { info in
                            Circle().fill(AccountPalette.color(info.colorIndex)).frame(width: 9, height: 9)
                        }
                    }
                    .accessibilityHidden(true)
                    Text("All accounts")
                }
            }
        }
        .menuStyle(.button)
        .controlSize(.large)
        .fixedSize()
        .help("Accounts to search")
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.accounts.filter { account == nil || $0.id == account }) { info in
                    WorkspaceSearchResults(
                        model: model, info: info, query: query,
                        selected: selected?.account == info.id ? selected?.message.id : nil
                    ) { message in
                        selected = MessageHit(account: info.id, message: message)
                    }
                }
            }
            .id(submission)
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
        }
    }

    private func submit() {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        selected = nil
        submission = UUID()
    }
}

private struct SearchMessageDetail: View {
    let model: AppModel
    let hit: MessageHit
    @State private var messages: [Message]?
    @State private var failed = false
    @State private var preview: PreviewTarget?

    /// "Today at 10:11", "Yesterday at 17:05", then the date.
    private static let when: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AccountBadge(info: model.info(hit.account), size: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(RemoteText.title(model.summary(for: hit.key)?.title ?? hit.key.space.rawValue))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(Self.when.string(from: hit.message.createTime.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Open latest messages") { model.openSearchConversation(hit.key) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            Divider()
            if failed {
                Text("Couldn’t load surrounding messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(messages ?? [hit.message]) { message in
                            MessageRow(row: .init(message: message, showsHeader: true, replies: 0), context: context)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .background(
                                    message.id == hit.message.id ? Theme.selection : .clear,
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
                .onChange(of: messages != nil) { proxy.scrollTo(hit.message.id, anchor: .center) }
            }
        }
        .sheet(item: $preview) { target in ImagePreviewSheet(target: target) { preview = nil } }
        .task(id: hit) {
            do {
                let window = try await model.searchContext(around: hit.message, account: hit.account)
                if !Task.isCancelled { messages = window }
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }

    private var context: MessageContext {
        var context = MessageContext(me: model.info(hit.account)?.me, messages: messages ?? [hit.message])
        if let media = model.mediaLoader(for: hit.account) {
            context.media = media
            context.openPreview = { preview = PreviewTarget(attachment: $0, media: media) }
            context.openGifPreview = { preview = PreviewTarget(gifURL: $0, media: media) }
        }
        return context
    }
}

/// Each workspace owns its page tokens. Only the displayed page's messages stay in memory.
private struct WorkspaceSearchResults: View {
    let model: AppModel
    let info: AccountInfo
    let query: String
    let selected: Message.ID?
    let select: (Message) -> Void
    @State private var cursors: [String] = []
    @State private var page: Page<Message>?
    @State private var failure: String?
    @State private var requestID = UUID()

    /// Searched words get a stronger Slate tint than a selected row, so they still show on one.
    private static let mark = Theme.dynamic(light: 0x4A_6382, dark: 0xA4_B1C0, lightAlpha: 0.24, darkAlpha: 0.32)

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            if let failure {
                HStack {
                    Text(failure).font(.callout).foregroundStyle(.secondary)
                    Button("Retry") { reload() }.controlSize(.small)
                }
                .padding(.horizontal, 8)
            } else if let page {
                if page.items.isEmpty {
                    Text("No matches on this page").font(.callout).foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
                ForEach(page.items) { message in
                    hitRow(message)
                }
                if page.skipped > 0 {
                    Text("Some results couldn’t be displayed.").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
            } else {
                ProgressView().controlSize(.small).padding(.horizontal, 8)
            }
            if !cursors.isEmpty || page?.nextPageToken != nil {
                HStack {
                    Button("Previous") {
                        cursors.removeLast()
                        reload()
                    }
                    .disabled(cursors.isEmpty)
                    Spacer()
                    Text("Page \(cursors.count + 1)").foregroundStyle(.secondary)
                    Spacer()
                    Button("Next") {
                        guard let token = page?.nextPageToken else { return }
                        cursors.append(token)
                        reload()
                    }
                    .disabled(page?.nextPageToken == nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: requestID) {
            do throws(SyncError) {
                let results = try await model.searchMessages(query, account: info.id, pageToken: cursors.last)
                guard !Task.isCancelled else { return }
                page = results
            } catch {
                guard !Task.isCancelled else { return }
                switch error {
                case .api(.invalidArgument, _): failure = "Google couldn’t interpret this search."
                case .api(.permissionDenied, _): failure = "Search isn’t available for this account."
                case .api(.unauthorized, _), .api(.noCredentials, _), .retired:
                    failure = "Reconnect this account in Settings."
                default: failure = "Couldn’t load this page."
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            AccountBadge(info: info, size: 14)
            Text(RemoteText.title(info.name)).lineLimit(1)
            Spacer(minLength: 8)
            // A count only means something when everything fits on one page.
            if let page, cursors.isEmpty, page.nextPageToken == nil, !page.items.isEmpty {
                Text(page.items.count == 1 ? "1 result" : "\(page.items.count) results")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .accessibilityAddTraits(.isHeader)
    }

    private func hitRow(_ message: Message) -> some View {
        let isSelected = message.id == selected
        let sender = RemoteText.title(message.sender.displayName ?? "Unknown")
        let key = SpaceKey(account: info.id, space: message.space)
        return Button {
            select(message)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Avatar(name: sender, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(sender).fontWeight(.semibold).lineLimit(1).layoutPriority(1)
                        Text(RemoteText.title(model.summary(for: key)?.title ?? message.space.rawValue))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(TimeFormat.relative(message.createTime))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    Text(Self.highlighted(RemoteText.preview(message.contentPreview ?? "Message"), query: query))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Marks each searched word in the preview. Search operators like `from:` and quotes aren't text to find.
    static func highlighted(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        let terms = query.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()")) }
            .filter { !$0.isEmpty && !$0.contains(":") && !["AND", "OR", "NOT"].contains($0) }
        for term in terms {
            var remaining = text.startIndex..<text.endIndex
            while let found = text.range(
                of: term, options: [.caseInsensitive, .diacriticInsensitive], range: remaining)
            {
                if let range = Range(found, in: attributed) {
                    attributed[range].backgroundColor = mark
                    attributed[range].foregroundColor = .primary
                }
                remaining = found.upperBound..<text.endIndex
            }
        }
        return attributed
    }

    private func reload() {
        page = nil
        failure = nil
        requestID = UUID()
    }
}
