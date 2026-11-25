import AppKit
import ChatModel
import ChatSync
import SwiftUI

struct ComposerView: View {
    let model: AppModel
    let key: SpaceKey
    let thread: ThreadName?

    @State private var text: String
    @State private var restored = false
    @State private var selection: TextSelection?
    @State private var pickerOpen = false
    @State private var mentionEditor = MentionEditor()
    @State private var candidates: [Contact] = []
    @State private var trigger: MentionEditor.Trigger?
    @State private var dismissedAt: Int?
    @State private var popupHighlight = 0
    @State private var dropTargeted = false
    @State private var edit: ActiveEdit?
    @FocusState private var focused: Bool
    private let previewMode: Bool
    /// A drag is over the conversation's messages, whose drops attach here, so the composer shows its drop outline.
    private let conversationDropTargeted: Bool

    init(
        model: AppModel, key: SpaceKey, thread: ThreadName?, previewText: String? = nil,
        conversationDropTargeted: Bool = false
    ) {
        self.model = model
        self.key = key
        self.thread = thread
        _text = State(initialValue: previewText ?? "")
        previewMode = previewText != nil
        self.conversationDropTargeted = conversationDropTargeted
    }

    private var composerID: ComposerID { ComposerID(key: key, thread: thread) }
    private var draft: ComposerDraft { model.composerDraft(composerID) }
    /// Off until the stored draft has loaded, and while the app quits; editing a sent message isn't a draft.
    private var editable: Bool { previewMode || edit != nil || restored && model.isComposerEditable(composerID) }

    var body: some View {
        let items = mentionItems
        let pending = draft.attachments
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.sendError {
                Text(error).font(.caption).foregroundStyle(Theme.error)
            }
            if let problem = model.attachmentError(for: composerID) {
                Text(problem).font(.caption).foregroundStyle(Theme.error)
            }
            if draft.loadFailed, !restored {
                HStack(spacing: 6) {
                    Text("The draft couldn't be loaded.").font(.caption).foregroundStyle(Theme.error)
                    Button("Try Again") { Task { await loadDraft() } }.buttonStyle(.link).font(.caption)
                }
            }
            if let edit { EditBar(edit: edit, onCancel: { finishEdit() }) }
            // Google Chat's per-conversation history setting; the org's retention rules apply only while it's on.
            if thread == nil, model.summary(for: key)?.historyOn == false {
                Label("History is off. Messages are deleted after about 24 hours.", systemImage: "timer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: chooseFiles) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: Self.attachSize, height: Self.attachSize)
                        .background(Color.primary.opacity(0.07), in: Circle())
                        .frame(height: Self.rowHeight)
                }
                .buttonStyle(.plain)
                .disabled(edit != nil || !editable)
                .help("Attach files")
                .accessibilityLabel("Attach files")
                VStack(alignment: .leading, spacing: 6) {
                    if !pending.isEmpty {
                        PendingAttachmentChips(attachments: pending) { model.removeAttachment($0, from: composerID) }
                            .padding(.top, 6)
                    }
                    HStack(alignment: .bottom, spacing: 6) {
                        if model.accounts.count > 1 {
                            let account = RemoteText.title(model.info(key.account)?.name ?? "")
                            AccountBadge(info: model.info(key.account), size: 18)
                                .frame(height: Self.rowHeight)
                                .help("Sending from \(account)")
                                .accessibilityLabel("Sending from \(account)")
                        }
                        editor(items)
                        Button {
                            pickerOpen = true
                        } label: {
                            Image(systemName: "face.smiling").font(.system(size: 17)).foregroundStyle(.secondary)
                                .frame(width: 26, height: Self.rowHeight)
                        }
                        .buttonStyle(.plain)
                        .help("Add emoji")
                        .accessibilityLabel("Add emoji")
                        .popover(isPresented: $pickerOpen, arrowEdge: .top) {
                            EmojiPicker(customEmojis: model.customEmojis(for: key.account)) { pick in
                                insert(pick.insertionText)
                            } onClose: {
                                pickerOpen = false
                                focused = true
                            }
                        }
                        Button(action: submit) {
                            Image(systemName: edit == nil ? "arrow.up" : "checkmark").font(
                                .system(size: 13, weight: .bold)
                            )
                            .foregroundStyle(canSend ? Theme.onAccent : Color.secondary)
                            .frame(width: Self.sendSize, height: Self.sendSize)
                            .background(canSend ? Theme.accent : Color.primary.opacity(0.08), in: Circle())
                            .frame(height: Self.rowHeight)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .help(edit == nil ? "Send (Return). Shift-Return adds a new line." : "Save (Return)")
                        .accessibilityLabel(edit == nil ? "Send" : "Save")
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, Self.sendInset)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: Self.rowHeight / 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Self.rowHeight / 2)
                        .strokeBorder(Color.secondary.opacity(0.28)))
            }
        }
        .padding(.horizontal, thread == nil ? 16 : 0)
        .padding(.top, 6)
        .padding(.bottom, thread == nil ? 14 : 2)
        .dropDestination(for: DroppedFile.self) { drops, _ in
            model.addDroppedFiles(drops, to: composerID)
        } isTargeted: {
            dropTargeted = $0
        }
        .overlay {
            if dropTargeted || conversationDropTargeted {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(
                    Theme.accentText, style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .overlay(
                    Text("Drop to add to message").font(.callout.weight(.medium)).foregroundStyle(Theme.accentText)
                )
                .background(Theme.selection, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if !items.isEmpty {
                MentionPopup(items: items, highlight: popupHighlight, onPick: pickMention)
                    .padding(.leading, thread == nil ? 60 : 44)
                    .frame(height: 0, alignment: .bottom)
            }
        }
        .task(id: model.pendingComposerFocus) {
            guard thread == nil, model.pendingComposerFocus == key else { return }
            try? await Task.sleep(for: .milliseconds(150))
            focused = true
            model.consumeComposerFocus(key)
        }
        .task(id: key) {
            // SwiftUI can rebuild the composer mid-edit; the new one picks the edit up again.
            if edit == nil { model.restartEdit(composerID) }
            startRequestedEdit()
            model.prepareMentions(for: key)
            await loadDraft()
            candidates = await model.mentionCandidates(for: key)
            guard !Task.isCancelled else { return }
            refreshTrigger()
        }
        // The draft changes under the composer when a failed send gives its text back.
        .onChange(of: draft.text) {
            if restored, edit == nil, draft.text != text { showDraft() }
        }
        .onChange(of: model.editRequests[composerID]?.id) {
            if model.editRequests[composerID] == nil {
                if edit != nil { finishEdit() }
            } else {
                startRequestedEdit()
            }
        }
        .onChange(of: model.summary(for: key)?.membersFetched) {
            Task {
                candidates = await model.mentionCandidates(for: key)
                refreshTrigger()
            }
        }
        .onChange(of: selection) { refreshTrigger() }
        .onChange(of: model.droppedTextRevision) { insertDroppedText() }
        .onChange(of: model.mentionRequestRevision) { insertRequestedMention() }
        .onChange(of: focused) {
            refreshTrigger()
            if focused {
                model.activeComposer = composerID
            } else if model.activeComposer == composerID {
                model.activeComposer = nil
            }
        }
    }

    private func editor(_ items: [Contact]) -> some View {
        TextEditor(text: editorBinding, selection: $selection)
            .disabled(!editable)
            .background(TextOnlyDrops())
            .font(.body)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .focused($focused)
            .frame(height: editorHeight)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
            }
            // The text view draws its first line at its very top, so this centres one line in the row; the
            // buttons beside it stay level with the last line as the text grows.
            .padding(.top, (Self.rowHeight - Self.lineHeight) / 2)
            .padding(.bottom, (Self.rowHeight - Self.lineHeight) / 2 - Self.editorSlack)
            .onKeyPress(.return, phases: .down) { press in
                if let pick = items[safe: popupHighlight] {
                    pickMention(pick)
                    return .handled
                }
                guard !press.modifiers.contains(.shift) else { return .ignored }
                submit()
                return .handled
            }
            .onKeyPress(.tab) {
                guard let pick = items[safe: popupHighlight] else { return .ignored }
                pickMention(pick)
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard !items.isEmpty else { return .ignored }
                popupHighlight = min(popupHighlight + 1, items.count - 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard !items.isEmpty else { return editLast() }
                popupHighlight = max(popupHighlight - 1, 0)
                return .handled
            }
            .onKeyPress(.escape) {
                guard !items.isEmpty, let trigger else {
                    guard edit != nil else { return .ignored }
                    finishEdit()
                    return .handled
                }
                dismissedAt = trigger.at
                return .handled
            }
    }

    private var placeholder: String {
        guard thread == nil else { return "Reply" }
        let title = RemoteText.title(model.summary(for: key)?.title ?? "")
        return title.isEmpty ? "Message" : "Message \(title)"
    }

    // MARK: Editing

    /// Only edits made through the editor are persisted; programmatic changes (restore, clear on send) never are.
    private var editorBinding: Binding<String> {
        Binding(
            get: { text },
            set: { newValue in
                guard newValue != text, !(edit.map { $0.saving || $0.basedOn == nil } ?? false) else { return }
                commit(newValue)
            })
    }

    /// Applies a user edit: shifts or drops mention ranges, schedules the draft save, re-evaluates the popup.
    private func commit(_ newValue: String) {
        mentionEditor.applyEdit(old: text, new: newValue)
        text = newValue
        saveDraft()
        refreshTrigger()
    }

    /// Types in text and links that reached a drop destination instead of the text view: dropped beside it, or a
    /// link offered without a text form. Waits for the draft to load, so a drop can't stand in for it and be saved
    /// over it.
    private func insertDroppedText() {
        guard restored else { return }
        let texts = model.takeDroppedText(composerID)
        guard !texts.isEmpty else { return }
        insert(texts.joined(separator: " "))
    }

    /// Inserts at the caret, replacing any selection.
    private func insert(_ addition: String) {
        var updated = text
        var caret = updated.utf16.count + addition.utf16.count
        if let selection, case .selection(let range) = selection.indices, range.upperBound <= updated.endIndex {
            let offset = updated.utf16.distance(from: updated.utf16.startIndex, to: range.lowerBound)
            updated.replaceSubrange(range, with: addition)
            caret = offset + addition.utf16.count
        } else {
            updated += addition
        }
        commit(updated)
        selection = TextSelection(insertionPoint: String.Index(utf16Offset: min(caret, text.utf16.count), in: text))
    }

    // MARK: Mentions

    private var isDirectMessage: Bool { model.summary(for: key)?.type == .directMessage }

    private var mentionItems: [Contact] {
        guard let trigger, dismissedAt != trigger.at else { return [] }
        var pool = candidates
        if !isDirectMessage { pool.insert(MentionEditor.allContact, at: 0) }
        return Array(MentionEditor.filter(pool, prefix: trigger.prefix).prefix(6))
    }

    private func caretOffset() -> Int? {
        guard let selection, case .selection(let range) = selection.indices else { return nil }
        guard range.isEmpty, range.lowerBound <= text.endIndex else { return nil }
        return text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
    }

    private func refreshTrigger() {
        var next: MentionEditor.Trigger?
        if (focused || previewMode) && (selection == nil || caretOffset() != nil) {
            next = mentionEditor.trigger(in: text, caret: caretOffset())
        }
        if next?.at != dismissedAt { dismissedAt = nil }
        if next != trigger { popupHighlight = 0 }
        trigger = next
    }

    private func pickMention(_ contact: Contact) {
        guard let trigger else { return }
        let result = mentionEditor.insert(contact, into: text, trigger: trigger)
        text = result.text
        saveDraft()
        self.trigger = nil
        selection = TextSelection(insertionPoint: String.Index(utf16Offset: result.caret, in: text))
    }

    /// The members list asked for this person to be mentioned: types "@" at the caret and picks them.
    private func insertRequestedMention() {
        guard let contact = model.takeMentionRequest(composerID) else { return }
        insert(startsWord(at: insertionOffset()) ? "@" : " @")
        guard let caret = caretOffset(), let found = mentionEditor.trigger(in: text, caret: caret) else { return }
        trigger = found
        pickMention(contact)
        focused = true
    }

    /// Where `insert` puts text: the start of the selection, or the end of the draft without one.
    private func insertionOffset() -> Int {
        if let selection, case .selection(let range) = selection.indices, range.upperBound <= text.endIndex {
            return text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
        }
        return text.utf16.count
    }

    /// Whether an "@" at `offset` starts a word, by the same rule the mention popup uses.
    private func startsWord(at offset: Int) -> Bool {
        guard offset > 0 else { return true }
        return MentionEditor.isWhitespace(text.utf16[text.utf16.index(text.utf16.startIndex, offsetBy: offset - 1)])
    }

    private var mentionNames: [UserName: String] {
        Dictionary(candidates.compactMap { contact in contact.user.map { ($0, contact.displayName) } }) { first, _ in
            first
        }
    }

    // MARK: Sending

    private var canSend: Bool {
        if let edit { return !edit.saving && edit.basedOn != nil }
        guard restored else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !draft.attachments.isEmpty
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to attach"
        guard panel.runModal() == .OK else { return }
        model.addFiles(panel.urls, to: composerID)
    }

    /// The height of one row of the composer: the field with a single line, and the slot each button sits in.
    static let rowHeight: CGFloat = 40
    /// The attach button, the same size as the window's glass buttons.
    static let attachSize: CGFloat = 36
    static let sendSize: CGFloat = 26
    /// Space between the send button and the field's right edge.
    static let sendInset: CGFloat = 8
    /// The text view's line height for the body font, emoji included.
    static let lineHeight: CGFloat = 16
    /// Room below the last line so the text view never needs to scroll by a fraction of a point.
    static let editorSlack: CGFloat = 2

    private var editorHeight: CGFloat {
        let lines = max(1, min(6, text.split(separator: "\n", omittingEmptySubsequences: false).count))
        return CGFloat(lines) * Self.lineHeight + Self.editorSlack
    }

    /// Hands the text to the draft store, which saves it after a pause; a sent message being edited isn't a draft.
    private func saveDraft() {
        guard edit == nil, !previewMode else { return }
        model.setDraftText(text, for: composerID)
    }

    private func loadDraft() async {
        guard !restored, !previewMode, await model.hydrateDraft(composerID), !Task.isCancelled else { return }
        restored = true
        if edit == nil { showDraft() }
        insertDroppedText()
    }

    /// Shows the stored draft in place of the field's text, which has no mentions of its own then.
    private func showDraft() {
        text = draft.text
        mentionEditor = MentionEditor()
        refreshTrigger()
    }

    private func submit() {
        guard canSend else { return }
        guard edit == nil else { return saveEdit() }
        let outgoing = text
        let sentMentions = mentionEditor
        let wire = mentionEditor.wireText(outgoing, names: mentionNames)
        guard let sending = model.sendDraft(wire, from: composerID) else { return }
        model.clearAttachmentError(composerID)
        text = ""
        mentionEditor = MentionEditor()
        trigger = nil
        Task {
            // The draft store gives the text back on failure; its mentions only the composer knows.
            if await !sending.value, edit == nil, draft.text == outgoing {
                text = outgoing
                mentionEditor = sentMentions
            }
        }
    }
}

// MARK: Editing a sent message

extension ComposerView {
    /// One edit in progress: `basedOn` is nil while the message loads.
    struct ActiveEdit: Equatable {
        let attempt: UUID
        let message: MessageName
        var basedOn: Timestamp?
        var original = ""
        var losesFormatting = false
        var saving = false
        var problem: String?
    }

    /// Up arrow in an empty composer edits my last message here.
    fileprivate func editLast() -> KeyPress.Result {
        guard edit == nil, restored, text.isEmpty, draft.attachments.isEmpty,
            let message = model.lastEditable(for: composerID)
        else { return .ignored }
        model.beginEdit(message, key: key)
        return .handled
    }

    fileprivate func startRequestedEdit() {
        guard let request = model.takeEditRequest(composerID) else { return }
        if edit == nil, restored, !model.hasStashedDraft(composerID) {
            model.stashDraft(StashedDraft(text: text, mentions: mentionEditor), for: composerID)
        }
        edit = ActiveEdit(attempt: request.id, message: request.message)
        text = ""
        mentionEditor = MentionEditor()
        trigger = nil
        focused = true
        Task {
            let result = await model.editableCopy(of: request.message, key: key)
            guard edit?.attempt == request.id, model.isCurrentEdit(request.id, in: composerID) else { return }
            switch result {
            case .success(let copy):
                text = copy.message.text
                mentionEditor = MentionEditor(mentions: MentionText.mentions(in: copy.message))
                edit?.basedOn = copy.message.version
                edit?.original = mentionEditor.wireText(text, names: mentionNames)
                edit?.losesFormatting = copy.losesFormatting
                selection = TextSelection(insertionPoint: text.endIndex)
            case .failure(.changed(let latest)):
                text = latest.text
                edit?.basedOn = latest.version
            case .failure(.message(let problem)):
                finishEdit()
                model.showComposerNotice(problem)
            }
        }
    }

    fileprivate func saveEdit() {
        guard let current = edit, let basedOn = current.basedOn, !current.saving else { return }
        let wire = mentionEditor.wireText(text, names: mentionNames)
        guard wire != current.original else { return finishEdit() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            edit?.problem = "A message can't be empty. Delete it instead."
            return
        }
        edit?.saving = true
        edit?.problem = nil
        Task {
            let result = await model.saveEdit(current.message, text: wire, basedOn: basedOn, key: key)
            guard edit?.attempt == current.attempt else { return }
            switch result {
            case .success:
                finishEdit()
            case .failure(.changed(let latest)):
                edit?.saving = false
                edit?.basedOn = latest.version
                edit?.problem = "Changed somewhere else since you started. Save again to replace that version."
            case .failure(.message(let problem)):
                edit?.saving = false
                edit?.problem = problem
            }
        }
    }

    /// Leaves edit mode and gives the draft back.
    fileprivate func finishEdit() {
        let attempt = edit?.attempt
        edit = nil
        trigger = nil
        model.endEdit(composerID, attempt: attempt)
        // The draft never changed during the edit; the stash only adds its mentions back.
        let stash = model.takeStashedDraft(composerID)
        text = draft.text
        mentionEditor = stash?.text == text ? stash?.mentions ?? MentionEditor() : MentionEditor()
        selection = TextSelection(insertionPoint: text.endIndex)
        focused = true
    }
}

/// Above the field while a sent message is being edited.
private struct EditBar: View {
    let edit: ComposerView.ActiveEdit
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "pencil")
                Text(edit.basedOn == nil ? "Loading message…" : edit.saving ? "Saving…" : "Editing message")
                    .fontWeight(.medium)
                Spacer()
                Text("Esc to cancel").foregroundStyle(.secondary)
                Button("Cancel", action: onCancel).buttonStyle(.borderless)
            }
            if edit.losesFormatting {
                Label(
                    "Formatting added in Google Chat (links, bold, lists) may be lost.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }
            if let problem = edit.problem {
                Text(problem).foregroundStyle(Theme.error)
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.accentText)
    }
}

struct MentionPopup: View {
    let items: [Contact]
    let highlight: Int
    let onPick: (Contact) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, contact in
                HStack(spacing: 8) {
                    if contact.user == .all {
                        Image(systemName: "megaphone").foregroundStyle(.secondary).frame(width: 22)
                        Text("@all").fontWeight(.medium)
                        Text("Notify everyone").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Avatar(name: RemoteText.title(contact.displayName), size: 22)
                        Text(RemoteText.title(contact.displayName)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    index == highlight ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
                .onTapGesture { onPick(contact) }
            }
        }
        .padding(5)
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mention suggestions")
    }
}

struct PendingAttachmentChips: View {
    let attachments: [PendingAttachment]
    var onRemove: (UUID) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(attachments) { attachment in
                HStack(spacing: 6) {
                    Image(
                        systemName: AttachmentIcon.symbol(
                            name: attachment.filename, contentType: attachment.contentType)
                    )
                    .foregroundStyle(.secondary)
                    Text(RemoteText.title(attachment.filename)).font(.callout).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 200)
                    Text(Int64(attachment.byteCount).formatted(.byteCount(style: .file)))
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        onRemove(attachment.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                    .accessibilityLabel("Remove \(RemoteText.title(attachment.filename))")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
                .accessibilityElement(children: .combine)
            }
        }
    }
}
