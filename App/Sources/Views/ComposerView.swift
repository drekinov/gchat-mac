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
    @State private var editRevision = 0
    @State private var saveTask: Task<Void, Never>?
    @State private var selection: TextSelection?
    @State private var pickerOpen = false
    @State private var mentionEditor = MentionEditor()
    @State private var candidates: [Contact] = []
    @State private var trigger: MentionEditor.Trigger?
    @State private var dismissedAt: Int?
    @State private var popupHighlight = 0
    @State private var dropTargeted = false
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

    var body: some View {
        let items = mentionItems
        let pending = model.attachments(for: composerID)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AccountBadge(info: model.info(key.account), size: 14)
                Text("Sending as \(RemoteText.title(model.info(key.account)?.name ?? "Unknown"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.sendError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Text("Return to send, Shift-Return for a new line").font(.caption2).foregroundStyle(.tertiary)
            }
            if !pending.isEmpty {
                PendingAttachmentChips(attachments: pending) { model.removeAttachment($0, from: composerID) }
            }
            if let problem = model.attachmentError(for: composerID) {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                editor(items)
                Button(action: chooseFiles) {
                    Image(systemName: "paperclip").font(.system(size: 19)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Attach files")
                .accessibilityLabel("Attach files")
                Button {
                    pickerOpen = true
                } label: {
                    Image(systemName: "face.smiling").font(.system(size: 20)).foregroundStyle(.secondary)
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
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(12)
        .dropDestination(for: DroppedFile.self) { drops, _ in
            model.addDroppedFiles(drops, to: composerID)
        } isTargeted: {
            dropTargeted = $0
        }
        .overlay {
            if dropTargeted || conversationDropTargeted {
                RoundedRectangle(cornerRadius: 8).strokeBorder(
                    Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .padding(4)
                .overlay(
                    Text("Drop to add to message").font(.callout.weight(.medium)).foregroundStyle(Color.accentColor)
                )
                .background(Color.accentColor.opacity(0.06))
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if !items.isEmpty {
                MentionPopup(items: items, highlight: popupHighlight, onPick: pickMention)
                    .padding(.leading, 12)
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
            model.prepareMentions(for: key)
            candidates = await model.mentionCandidates(for: key)
            guard !Task.isCancelled else { return }
            refreshTrigger()
            guard !restored else { return }
            let revision = editRevision
            let draft = await model.loadDraft(key, thread: thread)
            guard !Task.isCancelled else { return }
            restored = true
            if editRevision == revision, text.isEmpty { text = draft }
            insertDroppedText()
        }
        .onChange(of: model.snapshots[key.account]?.revision) {
            Task {
                candidates = await model.mentionCandidates(for: key)
                refreshTrigger()
            }
        }
        .onChange(of: selection) { refreshTrigger() }
        .onChange(of: model.droppedTextRevision) { insertDroppedText() }
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
            .background(TextOnlyDrops())
            .font(.body)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .frame(height: editorHeight)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(thread == nil ? "Message" : "Reply")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
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
                guard !items.isEmpty else { return .ignored }
                popupHighlight = max(popupHighlight - 1, 0)
                return .handled
            }
            .onKeyPress(.escape) {
                guard !items.isEmpty, let trigger else { return .ignored }
                dismissedAt = trigger.at
                return .handled
            }
    }

    // MARK: Editing

    /// Only edits made through the editor are persisted; programmatic changes (restore, clear on send) never are.
    private var editorBinding: Binding<String> {
        Binding(
            get: { text },
            set: { newValue in
                guard newValue != text else { return }
                commit(newValue)
            })
    }

    /// Applies a user edit: shifts or drops mention ranges, schedules the draft save, re-evaluates the popup.
    private func commit(_ newValue: String) {
        mentionEditor.applyEdit(old: text, new: newValue)
        text = newValue
        editRevision += 1
        scheduleSave()
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
        editRevision += 1
        scheduleSave()
        self.trigger = nil
        selection = TextSelection(insertionPoint: String.Index(utf16Offset: result.caret, in: text))
    }

    private var mentionNames: [UserName: String] {
        Dictionary(candidates.compactMap { contact in contact.user.map { ($0, contact.displayName) } }) { first, _ in
            first
        }
    }

    // MARK: Sending

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.attachments(for: composerID).isEmpty
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to attach"
        guard panel.runModal() == .OK else { return }
        model.addFiles(panel.urls, to: composerID)
    }

    private var editorHeight: CGFloat {
        let lines = max(1, min(6, text.split(separator: "\n", omittingEmptySubsequences: false).count))
        return CGFloat(lines) * 18 + 8
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = text
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await model.saveDraft(snapshot, key: key, thread: thread)
        }
    }

    private func submit() {
        guard canSend else { return }
        let outgoing = text
        let sentMentions = mentionEditor
        let sentAttachments = model.takeAttachments(composerID)
        model.clearAttachmentError(composerID)
        let wire = mentionEditor.wireText(outgoing, names: mentionNames)
        saveTask?.cancel()
        text = ""
        mentionEditor = MentionEditor()
        trigger = nil
        Task {
            if await !model.send(wire, key: key, thread: thread, attachments: sentAttachments) {
                model.restoreAttachments(sentAttachments, to: composerID)
                if text.isEmpty {
                    text = outgoing
                    mentionEditor = sentMentions
                }
            }
        }
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
                    index == highlight ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 5)
                )
                .contentShape(Rectangle())
                .onTapGesture { onPick(contact) }
            }
        }
        .padding(4)
        .frame(width: 300)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.35)))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
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
