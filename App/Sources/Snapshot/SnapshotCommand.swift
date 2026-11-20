#if DEBUG
    import AppKit
    import ChatModel
    import ChatSync
    import SwiftUI

    /// Renders windows into PNGs from offscreen windows, driven by the fake world.
    ///
    /// Every capture gets a fresh window: rows inserted into an already-laid-out `List` keep estimated heights
    /// offscreen, while a `List` built from loaded data lays out correctly.
    @MainActor
    final class SnapshotCommand {
        static func run(directory: String) async -> Int32 {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
            let requested = URL(fileURLWithPath: directory, isDirectory: true)
            let rig = SnapshotCommand(requested: requested, output: writableDirectory(requested: requested))
            let status = await rig.runAll()
            for url in rig.written { print("SNAPSHOT_PATH \(url.path)") }
            return status
        }

        let requested: URL
        let output: URL
        var written: [URL] = []

        init(requested: URL, output: URL) {
            self.requested = requested
            self.output = output
        }

        private func runAll() async -> Int32 {
            let model = AppModel()
            await model.boot(
                arguments: ["--fake", "--fake-accounts", "3"], fakeTraffic: false, promptForNotifications: false)
            guard await Self.settle(model, accounts: 3) else {
                print("snapshot: no spaces appeared within 10 s")
                return 1
            }
            guard let threaded = model.inbox.first(where: { model.kind(of: $0) == .space && model.isThreaded($0.id) })
            else {
                print("snapshot: no threaded space")
                return 1
            }

            let wide = NSSize(width: 1280, height: 800)
            model.select(threaded.id)
            await mainWindow("01-space-threads.png", model, wide)

            if let dm = model.inbox.first(where: { model.kind(of: $0) == .directMessage }) {
                model.select(dm.id)
                await mainWindow("02-direct-message.png", model, wide)
            }

            model.select(threaded.id)
            await model.waitUntilSettled(timeout: .seconds(3))
            if let thread = model.openMessages.last(where: \.isThreadReply)?.thread,
                let index = model.accounts.firstIndex(where: { $0.id == threaded.account }),
                let server = model.world?.servers[safe: index],
                let account = server.requests.compactMap(\.account).first
            {
                server.setThreadReadState(account, thread: thread, lastReadTime: nil)
                let start = server.requests.count
                model.openThread(thread)
                await mainWindow(
                    "03-thread-inspector.png", model, wide,
                    onLayout: {
                        // Offscreen windows can be inactive. Exercise focus after the viewport has been laid out.
                        model.windowIsKey = true
                        await Self.pump(.seconds(1))
                    })
                let wrote = server.requests.dropFirst(start).contains {
                    $0.path == "/v1/users/me/\(thread.rawValue)/threadReadState" && $0.method == "PATCH"
                        && $0.status == 200
                }
                print("snapshot: visible thread read state synced=\(wrote)")
                guard wrote else { return 1 }
                model.closeThread()
            }

            if let account = model.accounts.dropFirst().first {
                model.accountFilter = account.id
                await mainWindow("04-account-filter.png", model, wide)
            }
            model.accountFilter = nil

            model.prepareMentions(for: threaded.id)
            await model.waitUntilSettled(timeout: .seconds(3))
            let members = await model.memberships(for: threaded.id)
            print("snapshot: members of the threaded space: \(members.count)")
            await window(
                "28-members.png",
                MembersPopover(model: model, key: threaded.id, members: members) {}
                    .background(Color(nsColor: .windowBackgroundColor)),
                NSSize(width: 340, height: 520))
            await window(
                "29-details.png",
                ConversationDetailsPopover(model: model, key: threaded.id, members: members)
                    .background(Color(nsColor: .windowBackgroundColor)),
                NSSize(width: 340, height: 280))

            await window(
                "26-message-search.png", MessageSearchSheet(model: model, initialQuery: "release"),
                MessageSearchSheet.size)

            let showcases: [(file: String, title: String, size: NSSize)] = [
                ("05-reactions-and-emoji.png", "Engineering", wide),
                ("06-attachments.png", "Releases", NSSize(width: 1280, height: 1500)),
                ("07-quoted-card-mention.png", "Design Reviews", wide),
                ("30-history-off.png", "On-call Handover", wide),
            ]
            for item in showcases {
                if let entry = model.inbox.first(where: { $0.summary.title == item.title }) {
                    model.select(entry.id)
                    await mainWindow(item.file, model, item.size)
                }
            }

            if let entry = model.inbox.first(where: { $0.summary.title == "Engineering" }) {
                model.select(entry.id)
                let suite = UserDefaults(suiteName: "io.github.drekinov.gchat-mac.snapshot")
                suite?.set(SidebarDensity.compact.rawValue, forKey: "sidebarDensity")
                if let suite {
                    await mainWindow("08-compact-sidebar.png", model, wide, defaults: suite)
                }
                suite?.removePersistentDomain(forName: "io.github.drekinov.gchat-mac.snapshot")
            }

            if let entry = model.inbox.first(where: { $0.summary.title == "Engineering" }) {
                model.select(entry.id)
                await model.waitUntilSettled(timeout: .seconds(3))
                if let target = model.openMessages.last(where: { $0.text.hasPrefix("Release 4.2") }) {
                    if let rocket = target.reactions.first {
                        await window(
                            "31-reactors.png",
                            ReactorsCard(
                                reaction: rocket, summaries: target.reactions, message: target.name,
                                actions: model.reactionActions(for: entry.id)
                            )
                            .background(Color(nsColor: .windowBackgroundColor)),
                            NSSize(width: 260, height: 300))
                    }
                    await mainWindow("12-hover-action-bar.png", model, wide, hovering: target.name)
                    await reactionRoundTrip(model, entry.id, target.name)
                    await mainWindow("16-after-toggle.png", model, wide, hovering: target.name)
                }
            }

            let customEmojis = model.accounts.first.map { model.customEmojis(for: $0.id) } ?? []
            let picker = { (query: String) in
                EmojiPicker(customEmojis: customEmojis, initialQuery: query, onPick: { _ in })
                    .background(Color(nsColor: .windowBackgroundColor))
            }
            await window("13-emoji-picker.png", picker(""), EmojiPicker.size)
            await window("14-emoji-picker-search.png", picker("heart"), EmojiPicker.size)
            let tones = UserDefaults(suiteName: "io.github.drekinov.gchat-mac.snapshot.tone")
            tones?.set(4, forKey: "emojiSkinTone")
            if let tones {
                await window(
                    "15-emoji-picker-skin-tone.png", picker("hand").defaultAppStorage(tones), EmojiPicker.size)
                tones.removePersistentDomain(forName: "io.github.drekinov.gchat-mac.snapshot.tone")
            }

            if let entry = model.inbox.first(where: { $0.summary.title == "Engineering" }) {
                model.select(entry.id)
                await mentionChecks(model, entry.id)
                let preview = VStack(spacing: 0) {
                    Color(nsColor: .textBackgroundColor).frame(height: 200)
                    ComposerView(model: model, key: entry.id, thread: nil, previewText: "Thanks @mo")
                }
                .background(Color(nsColor: .windowBackgroundColor))
                await window("20-mention-popup.png", preview, NSSize(width: 640, height: 340))
                let all = VStack(spacing: 0) {
                    Color(nsColor: .textBackgroundColor).frame(height: 200)
                    ComposerView(model: model, key: entry.id, thread: nil, previewText: "@")
                }
                .background(Color(nsColor: .windowBackgroundColor))
                await window("21-mention-popup-all.png", all, NSSize(width: 640, height: 340))
            }

            for tab in SettingsTab.allCases {
                await window(
                    "09-settings-\(tab.rawValue).png", SettingsView(model: model, initialTab: tab), SettingsView.size)
            }

            model.openNewMessage()
            for (file, text) in [
                ("17-new-message-empty.png", ""), ("18-new-message-search.png", "a"),
                ("19-new-message-email.png", "new.person@example.com"),
            ] {
                await window(
                    file,
                    NewMessageSheet(model: model, onClose: {}, snapshotQuery: text)
                        .background(Color(nsColor: .windowBackgroundColor)),
                    NSSize(width: 480, height: 560))
            }

            if let account = model.accounts.first {
                let found = await model.searchDirectory("ch", for: account.id)
                print("snapshot: directory results for 'ch': \(found.map(\.displayName))")
                if let person = found.first {
                    let failure = await model.startDirectMessage(person, account: account.id)
                    print("snapshot: start DM with \(person.displayName): \(failure ?? "ok")")
                    await model.waitUntilSettled(timeout: .seconds(3))
                    print(
                        "snapshot: selected \(model.selection.map { model.summary(for: $0)?.title ?? "?" } ?? "none")")
                    await mainWindow("22-new-dm-opened.png", model, wide)
                }
                if let existing = await model.contacts(for: account.id).first(where: { $0.directMessage != nil }) {
                    let failure = await model.startDirectMessage(existing, account: account.id)
                    print(
                        "snapshot: reuse DM with \(existing.displayName): \(failure ?? "ok") selected=\(model.selection?.space == existing.directMessage)"
                    )
                }
            }

            await window(
                "10-quick-switcher.png", QuickSwitcher(model: model).background(Color(nsColor: .windowBackgroundColor)),
                NSSize(width: 500, height: 520))

            // The first run: no accounts yet, with a saved client.
            await window(
                "27-first-run.png",
                SignInView(model: model, snapshotClient: "example-chat")
                    .background(Color(nsColor: .windowBackgroundColor)), wide)

            let suite = UserDefaults(suiteName: "io.github.drekinov.gchat-mac.snapshot.notify")
            suite?.set(true, forKey: NotificationCenterPoster.enabledKey)
            if let suite {
                await window(
                    "09-settings-notifications-enabled.png",
                    TabView {
                        NotificationsSettings(statusOverride: .authorized)
                            .tabItem { Label("Notifications", systemImage: "bell") }
                    }
                    .frame(width: SettingsView.size.width, height: SettingsView.size.height)
                    .defaultAppStorage(suite), SettingsView.size)
                suite.removePersistentDomain(forName: "io.github.drekinov.gchat-mac.snapshot.notify")
            }

            await mediaChecks(model, wide)

            model.shutdown()
            let many = AppModel()
            await many.boot(
                arguments: ["--fake", "--fake-accounts", "5"], fakeTraffic: false, promptForNotifications: false)
            guard await Self.settle(many, accounts: 5) else {
                print("snapshot: five-account world did not settle")
                return 1
            }
            if let first = many.inbox.first { many.select(first.id) }
            await mainWindow("11-five-accounts.png", many, wide)
            many.shutdown()
            return 0
        }

        private func writeFile(_ name: String, _ data: Data) -> URL {
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "snapshot-files", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: name, directoryHint: .notDirectory)
            try? data.write(to: url)
            return url
        }

        /// Attaching, uploading, failing, inline loading, the redirect path, GIF decoding and exporting, all for real.
        private func mediaChecks(_ model: AppModel, _ wide: NSSize) async {
            let library = FakeLibrary.shared
            guard let entry = model.inbox.first(where: { $0.summary.title == "Design Reviews" }),
                let index = model.accounts.firstIndex(where: { $0.id == entry.account }),
                let server = model.world?.servers[safe: index]
            else { return print("snapshot: media checks skipped") }
            model.select(entry.id)
            await model.waitUntilSettled(timeout: .seconds(3))
            let id = ComposerID(key: entry.id, thread: nil)

            let png = writeFile("upload-check.png", library.landscape.data)
            let pdf = writeFile("agenda.pdf", library.pdf.data)
            let huge = FileManager.default.temporaryDirectory.appending(path: "snapshot-files/too-big.bin")
            FileManager.default.createFile(atPath: huge.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: huge) {
                try? handle.truncate(atOffset: UInt64(201 << 20))
                try? handle.close()
            }
            print(
                "snapshot: security-scoped bookmark creation works: \((try? SecurityScopedFileAccess.bookmark(for: png)) != nil)"
            )
            model.addFiles([png, pdf, huge], to: id)
            print(
                "snapshot: queued \(model.attachments(for: id).map(\.filename)) problem: \(model.attachmentError(for: id) ?? "none")"
            )
            let composer = VStack(spacing: 0) {
                Color(nsColor: .textBackgroundColor).frame(height: 120)
                ComposerView(model: model, key: entry.id, thread: nil, previewText: "Here are the files")
            }
            .background(Color(nsColor: .windowBackgroundColor))
            await window("23-composer-attachments.png", composer, NSSize(width: 640, height: 260))

            let sent = await model.send(
                "Upload check", key: entry.id, thread: nil, attachments: model.takeAttachments(id))
            var delivered: Message?
            for _ in 0..<150 {
                delivered = server.messages(in: entry.summary.name).last { $0.text == "Upload check" }
                if delivered != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let names = delivered?.attachments.map(\.contentName) ?? []
            var bytesMatch = false
            if let first = delivered?.attachments.first, case .uploaded(let resource) = first.source {
                bytesMatch = server.mediaBytes(resource) == library.landscape.data
            }
            print("snapshot: upload sent=\(sent) delivered attachments=\(names) first bytes match=\(bytesMatch)")

            let gone = writeFile("gone.txt", Data("bye".utf8))
            model.addFiles([gone], to: id)
            try? FileManager.default.removeItem(at: gone)
            _ = await model.send(
                "Upload failure check", key: entry.id, thread: nil, attachments: model.takeAttachments(id))
            var reason = "none"
            for _ in 0..<150 {
                await model.waitUntilSettled(timeout: .seconds(1))
                if let failed = model.openOutbox.first(where: { $0.state.isTerminal }),
                    case .failed(let why) = failed.state
                {
                    reason = why
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            print("snapshot: failure reason: \(reason)")
            await mainWindow("24-upload-failure.png", model, wide)

            // Releases: inline images, GIF decoding and export.
            if let releases = model.inbox.first(where: { $0.summary.title == "Releases" }),
                let loader = model.mediaLoader(for: releases.account)
            {
                model.select(releases.id)
                await model.waitUntilSettled(timeout: .seconds(3))
                if let attachment = model.openMessages.flatMap(\.attachments).first(where: {
                    $0.contentName == "Release-notes-4.2.pdf"
                }) {
                    do {
                        let url = try await loader.export(attachment)
                        let quarantine = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
                        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                        print(
                            "snapshot: export ok=\(FileManager.default.fileExists(atPath: url.path)) bytes=\(size) quarantined=\(quarantine > 0)"
                        )
                    } catch {
                        print("snapshot: export failed: \(error)")
                    }
                }
                do {
                    let animation = try await loader.animation(at: FakeLibrary.gifURL, maxPixelSize: 512)
                    let frame = try await animation.frame(at: 1)
                    print(
                        "snapshot: gif frames=\(animation.frameCount) delay=\(animation.delay(at: 0)) frame1=\(frame.image.width)x\(frame.image.height)"
                    )
                } catch {
                    print("snapshot: gif failed: \(error)")
                }
                if let attachment = model.openMessages.flatMap(\.attachments).first(where: {
                    $0.contentName == "screenshot-onboarding.png"
                }) {
                    let target = PreviewTarget(
                        attachment: attachment, media: loader, messages: [model.openMessages],
                        space: model.summary(for: releases.id))
                    let size = NSSize(width: 900, height: 640)
                    await window(
                        "25-image-preview.png",
                        ImagePreviewSheet(target: target) {}.environment(\.isSnapshotMode, true), size)
                    await window(
                        "25-image-preview-zoomed.png",
                        ImagePreviewSheet(target: target, startZoom: 2) {}.environment(\.isSnapshotMode, true), size)
                }
            }

            // Org B's server redirects downloads to an unauthenticated host.
            if let orgB = model.accounts.dropFirst(FakeWorld.redirectOrgIndex).first,
                let redirectServer = model.world?.servers[safe: FakeWorld.redirectOrgIndex],
                let loader = model.mediaLoader(for: orgB.id),
                let message = model.inbox.filter({ $0.account == orgB.id }).flatMap({
                    redirectServer.messages(in: $0.summary.name)
                }).first(where: { $0.attachments.contains { $0.contentName == "redirect-check.png" } }),
                let attachment = message.attachments.first
            {
                do {
                    let image = try await loader.image(attachment, maxPixelSize: 512)
                    let hits = redirectServer.mediaHostRequests
                    print(
                        "snapshot: redirect image \(image.image.width)x\(image.image.height) host hits=\(hits.count) credentials=\(hits.contains { $0.hadCredentials })"
                    )
                    image.reservation.release()
                } catch {
                    print("snapshot: redirect failed: \(mediaFailureText(error))")
                }
            }
        }

        /// Drives the mention editor the way the composer does and prints the wire text.
        private func mentionChecks(_ model: AppModel, _ key: SpaceKey) async {
            let candidates = await model.mentionCandidates(for: key)
            print("snapshot: mention candidates: \(candidates.map(\.displayName))")
            var editor = MentionEditor()
            var text = "Hi @"
            func complete(_ prefix: String) {
                let typed = text + prefix
                editor.applyEdit(old: text, new: typed)
                text = typed
                guard let trigger = editor.trigger(in: text, caret: nil),
                    let pick = MentionEditor.filter([MentionEditor.allContact] + candidates, prefix: trigger.prefix)
                        .first
                else { return print("snapshot: no mention match for \(prefix)") }
                text = editor.insert(pick, into: text, trigger: trigger).text
            }
            let first = candidates.first?.displayName.prefix(2).lowercased() ?? "mo"
            let second = candidates.dropFirst().first?.displayName.prefix(2).lowercased() ?? "ge"
            complete(String(first))
            let typed = text + "and @"
            editor.applyEdit(old: text, new: typed)
            text = typed
            complete(String(second))
            let names = Dictionary(
                uniqueKeysWithValues: candidates.compactMap { c in c.user.map { ($0, c.displayName) } })
            print("snapshot: visible: \(text)")
            print("snapshot: wire:    \(editor.wireText(text, names: names))")
            let edited = text.replacingOccurrences(of: "@" + (candidates.first?.displayName ?? ""), with: "@X")
            editor.applyEdit(old: text, new: edited)
            print("snapshot: after editing first mention, wire: \(editor.wireText(edited, names: names))")
        }

        /// Toggles through the real session against the fake: remove an own reaction, re-add it, add a new one.
        private func reactionRoundTrip(_ model: AppModel, _ key: SpaceKey, _ message: MessageName) async {
            func count(_ emoji: Emoji) -> Int {
                model.openMessages.first { $0.name == message }?.reactions.first { $0.emoji == emoji }?.count ?? 0
            }
            func wait(_ emoji: Emoji, until target: Int) async -> Bool {
                for _ in 0..<100 {
                    if count(emoji) == target { return true }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return false
            }
            let party = Emoji.unicode("🎉")
            let thinking = Emoji.unicode("🤔")
            let start = count(party)
            print("snapshot: reaction mine before: \(model.ownReaction(party, on: message) != nil), count \(start)")
            await model.toggleReaction(party, on: message, key: key)
            let removed = await wait(party, until: start - 1)
            print(
                "snapshot: reaction removed ok=\(removed) mine=\(model.ownReaction(party, on: message) != nil) count=\(count(party))"
            )
            await model.toggleReaction(party, on: message, key: key)
            let restored = await wait(party, until: start)
            print("snapshot: reaction re-added ok=\(restored) count=\(count(party))")
            await model.toggleReaction(thinking, on: message, key: key)
            let added = await wait(thinking, until: 1)
            print("snapshot: reaction new ok=\(added) mine=\(model.ownReaction(thinking, on: message) != nil)")
        }

        private func mainWindow(
            _ name: String, _ model: AppModel, _ size: NSSize, defaults: UserDefaults? = nil,
            hovering: MessageName? = nil, onLayout: (() async -> Void)? = nil
        ) async {
            await model.waitUntilSettled(timeout: .seconds(3))
            let root = ContentView(model: model).environment(\.isSnapshotMode, true)
                .environment(\.forcedHoverMessage, hovering)
            if let defaults {
                await window(name, root.defaultAppStorage(defaults), size, onLayout: onLayout)
            } else {
                await window(name, root, size, onLayout: onLayout)
            }
        }

        private func window<V: View>(_ name: String, _ root: V, _ size: NSSize, onLayout: (() async -> Void)? = nil)
            async
        {
            let window = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: 20, y: 20), size: size), styleMask: [.borderless],
                backing: .buffered, defer: false)
            // Offscreen renders can't draw glass, so every view gets the flat stand-ins snapshot mode provides.
            let host = NSHostingView(rootView: root.environment(\.isSnapshotMode, true))
            host.frame = NSRect(origin: .zero, size: size)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.alphaValue = 0.01
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
            window.makeKey()
            await Self.pump(.milliseconds(1800))
            await onLayout?()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            defer { window.close() }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                print("snapshot: no bitmap rep for \(name)")
                return
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                print("snapshot: PNG encoding failed for \(name)")
                return
            }
            let url = output.appending(path: name, directoryHint: .notDirectory)
            do {
                try png.write(to: url)
                written.append(url)
                print("SNAPSHOT_PNG \(name) \(png.base64EncodedString())")
            } catch {
                print("snapshot: write failed: \(error)")
            }
        }

        private static func spinOnce() {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }

        /// Runs the run loop so AppKit and SwiftUI perform their deferred layout and display passes.
        private static func pump(_ duration: Duration) async {
            let end = ContinuousClock.now + duration
            while ContinuousClock.now < end {
                spinOnce()
                await Task.yield()
            }
        }

        /// The sandboxed app can't write into the repository, so it falls back to its container's temp directory.
        private static func writableDirectory(requested wanted: URL) -> URL {
            let fallback = FileManager.default.temporaryDirectory.appending(
                path: "snapshots", directoryHint: .isDirectory)
            for candidate in [wanted, fallback] {
                do {
                    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
                    let probe = candidate.appending(path: ".probe", directoryHint: .notDirectory)
                    try Data().write(to: probe)
                    try FileManager.default.removeItem(at: probe)
                    return candidate
                } catch {
                    continue
                }
            }
            return fallback
        }

        private static func settle(_ model: AppModel, accounts: Int) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                let ready =
                    model.accounts.count == accounts
                    && model.accounts.allSatisfy { !(model.snapshots[$0.id]?.spaces.isEmpty ?? true) }
                if ready { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !model.inbox.isEmpty else { return false }
            let titlesDeadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < titlesDeadline {
                if !model.inbox.contains(where: { ["Direct message", "Group chat"].contains($0.summary.title) }) {
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return true
        }
    }
#endif
