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
    @State private var path: [MessageHit] = []
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, initialQuery: String = "") {
        self.model = model
        _account = State(initialValue: model.accountFilter)
        _text = State(initialValue: initialQuery)
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search messages").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            NavigationStack(path: $path) {
                VStack(spacing: 0) {
                    HStack {
                        TextField("Search Google Chat", text: $text)
                            .textFieldStyle(.roundedBorder)
                            .focused($focused)
                            .onSubmit(submit)
                        Picker("Account", selection: $account) {
                            Text("All accounts").tag(nil as AccountID?)
                            ForEach(model.accounts) { info in
                                Text(RemoteText.title(info.name)).tag(Optional(info.id))
                            }
                        }
                        .labelsHidden().fixedSize()
                        Button("Search", action: submit).disabled(
                            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding()
                    Divider()
                    if query.isEmpty {
                        ContentUnavailableView("Search your messages", systemImage: "magnifyingglass")
                    } else if query.unicodeScalars.count > 1000 {
                        ContentUnavailableView("Use 1,000 characters or fewer", systemImage: "text.magnifyingglass")
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(model.accounts.filter { account == nil || $0.id == account }) { info in
                                    WorkspaceSearchResults(model: model, info: info, query: query) { message in
                                        path.append(MessageHit(account: info.id, message: message))
                                    }
                                }
                            }
                            .id(submission)
                            .padding()
                        }
                    }
                    Spacer(minLength: 0)
                }
                .navigationDestination(for: MessageHit.self) { hit in
                    SearchMessageDetail(model: model, hit: hit)
                }
            }
        }
        .frame(width: 650, height: 490)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focused = true }
        .onChange(of: model.accounts.map(\.id)) {
            path.removeAll()
            if let account, model.info(account) == nil { self.account = nil }
        }
    }

    private func submit() {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        submission = UUID()
    }
}

private struct SearchMessageDetail: View {
    let model: AppModel
    let hit: MessageHit
    @State private var messages: [Message]?
    @State private var failed = false
    @State private var preview: PreviewTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AccountChip(info: model.info(hit.account))
                Text(RemoteText.title(model.summary(for: hit.key)?.title ?? hit.key.space.rawValue)).font(.headline)
                Spacer()
                Button("Open latest messages") { model.openSearchConversation(hit.key) }
            }
            Text(hit.message.createTime.date.formatted()).font(.caption).foregroundStyle(.secondary)
            Divider()
            if failed { Text("Couldn’t load surrounding messages.").font(.caption) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(messages ?? [hit.message]) { message in
                            MessageRow(row: .init(message: message, showsHeader: true, replies: 0), context: context)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .background(
                                    message.id == hit.message.id ? Color.accentColor.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .id(message.id)
                        }
                    }
                }
                .onChange(of: messages != nil) { proxy.scrollTo(hit.message.id, anchor: .center) }
            }
        }
        .padding()
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
    let select: (Message) -> Void
    @State private var cursors: [String] = []
    @State private var page: Page<Message>?
    @State private var failure: String?
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AccountChip(info: info)
            if let failure {
                HStack {
                    Text(failure).foregroundStyle(.secondary)
                    Button("Retry") { reload() }
                }
            } else if let page {
                if page.items.isEmpty { Text("No matches on this page").foregroundStyle(.secondary) }
                ForEach(page.items) { message in
                    Button {
                        select(message)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                let key = SpaceKey(account: info.id, space: message.space)
                                Text(RemoteText.title(model.summary(for: key)?.title ?? message.space.rawValue)).bold()
                                Text(RemoteText.title(message.sender.displayName ?? "Unknown"))
                                Spacer()
                                Text(message.createTime.date.formatted(date: .abbreviated, time: .shortened))
                            }
                            .font(.caption)
                            Text(RemoteText.preview(message.contentPreview ?? "Message")).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                if page.skipped > 0 { Text("Some results couldn’t be displayed.").font(.caption) }
            } else {
                ProgressView().controlSize(.small)
            }
            if !cursors.isEmpty || page?.nextPageToken != nil {
                HStack {
                    Button("Previous") {
                        cursors.removeLast()
                        reload()
                    }
                    .disabled(cursors.isEmpty)
                    Text("Page \(cursors.count + 1)").foregroundStyle(.secondary)
                    Button("Next") {
                        guard let token = page?.nextPageToken else { return }
                        cursors.append(token)
                        reload()
                    }
                    .disabled(page?.nextPageToken == nil)
                }
                .controlSize(.small)
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

    private func reload() {
        page = nil
        failure = nil
        requestID = UUID()
    }
}
