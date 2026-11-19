#if DEBUG
    import AppKit
    import ChatModel
    import ChatSync
    import ObjectiveC
    import SwiftUI
    import UniformTypeIdentifiers

    /// `--drop-test`: drives drag-and-drop into the main and thread composers of the sample world without a mouse.
    /// For each payload and drop spot it builds the pasteboard a real drag carries, asks AppKit's own window routing
    /// (`-[NSWindow _findDragTargetFrom:]`) which view the drag would reach, delivers the drop to that view with a mock
    /// `NSDraggingInfo` and checks exactly what the composer got.
    ///
    /// File promises (the screenshot thumbnail, Safari bookmarks) aren't covered: `NSFilePromiseReceiver` asserts
    /// outside a real drag session.
    @MainActor
    final class DropTestCommand {
        static func run() async -> Int32 {
            setvbuf(stdout, nil, _IONBF, 0)
            NSApplication.shared.setActivationPolicy(.accessory)
            return await DropTestCommand().runAll()
        }

        private var failures = 0
        private var ran = 0
        private let scratch = FileManager.default.temporaryDirectory.appending(
            path: "drop-test", directoryHint: .isDirectory)

        private func runAll() async -> Int32 {
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let model = AppModel()
            await model.boot(
                arguments: ["--fake", "--fake-accounts", "1"], fakeTraffic: false, promptForNotifications: false)
            guard await Self.settle(model), let entry = model.inbox.first(where: { model.isThreaded($0.id) }) else {
                print("DROPTEST FAIL no threaded space")
                return 1
            }
            model.select(entry.id)
            await model.waitUntilSettled(timeout: .seconds(3))
            guard let thread = model.openMessages.last(where: \.isThreadReply)?.thread else {
                print("DROPTEST FAIL no thread to open")
                return 1
            }
            model.openThread(thread)

            let window = NSWindow(
                contentRect: NSRect(x: 20, y: 20, width: 1280, height: 800), styleMask: [.borderless],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ContentView(model: model))
            window.alphaValue = 0.01
            window.orderFrontRegardless()
            window.makeKey()
            await Self.pump(.seconds(2.5))
            defer { window.close() }

            // The thread inspector sits to the right of the conversation.
            let editors = Self.textViews(in: window).filter(\.isEditable).sorted {
                $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
            }
            guard editors.count == 2, model.openThread == thread else {
                print("DROPTEST FAIL expected the main and thread composers, found \(editors.count) editors")
                return 1
            }
            let composers = [
                ("main", editors[0], ComposerID(key: entry.id, thread: nil)),
                ("thread", editors[1], ComposerID(key: entry.id, thread: thread)),
            ]
            for (name, textView, id) in composers {
                // Anywhere in the visible field (the text view is a 26 pt strip inside a padded box) and, for the
                // main composer, on the message list, whose drops attach to it.
                for spot in Spot.allCases where spot != .messageList || name == "main" {
                    for payload in Payload.allCases {
                        await check(
                            payload, at: spot, on: name, textView: textView, id: id, model: model, window: window)
                    }
                }
            }
            let expected = Payload.allCases.count * (2 * Spot.allCases.count - 1)
            guard ran == expected else {
                print("DROPTEST FAIL ran \(ran) of \(expected) cases")
                return 1
            }
            await checkStagedCopyRemoval(textView: editors[0], id: composers[0].2, model: model, window: window)
            checkLinkFiles()
            await checkRepresentations()
            await reportFileWithText(textView: editors[0], id: composers[0].2, model: model, window: window)
            await checkDroppedTextQueue(current: entry.id, model: model, window: window)
            print("DROPTEST \(failures == 0 ? "ALL \(ran) PASSED" : "\(failures) OF \(ran) FAILED")")
            try? FileManager.default.removeItem(at: scratch)
            return failures == 0 ? 0 : 1
        }

        enum Payload: String, CaseIterable {
            case plainText, finderPDF, webLink
        }

        /// Where the drop lands, relative to the composer's text view.
        enum Spot: String, CaseIterable {
            case textCentre, boxTopPadding, boxBottomPadding, boxLeftPadding, messageList

            func point(in frame: NSRect) -> NSPoint {
                switch self {
                case .textCentre: NSPoint(x: frame.midX, y: frame.midY)
                case .boxTopPadding: NSPoint(x: frame.midX, y: frame.maxY + 2)
                case .boxBottomPadding: NSPoint(x: frame.midX, y: frame.minY - 2)
                case .boxLeftPadding: NSPoint(x: frame.minX - 3, y: frame.midY)
                case .messageList: NSPoint(x: frame.midX, y: frame.maxY + 200)
                }
            }
        }

        private func check(
            _ payload: Payload, at spot: Spot, on name: String, textView: NSTextView, id: ComposerID,
            model: AppModel, window: NSWindow
        ) async {
            ran += 1
            textView.string = ""
            textView.didChangeText()
            for attachment in model.attachments(for: id) { model.removeAttachment(attachment.id, from: id) }
            await Self.pump(.milliseconds(200))

            let pasteboard = NSPasteboard(name: NSPasteboard.Name("drop-test-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            let expectedText: String
            let expectedChips: Int
            switch payload {
            case .plainText:
                pasteboard.setString("Test", forType: .string)
                pasteboard.setData(Data("{\\rtf1 Test}".utf8), forType: .rtf)
                (expectedText, expectedChips) = ("Test", 0)
            case .finderPDF:
                let file = scratch.appending(path: "Report.pdf")
                try? Data("%PDF-1.4\n%%EOF\n".utf8).write(to: file)
                pasteboard.writeObjects([file as NSURL])
                (expectedText, expectedChips) = ("", 1)
            case .webLink:
                let link = "https://example.com/page"
                pasteboard.writeObjects([URL(string: link)! as NSURL])
                pasteboard.addTypes([.string], owner: nil)
                pasteboard.setString(link, forType: .string)
                (expectedText, expectedChips) = (link, 0)
            }

            let point = spot.point(in: textView.convert(textView.bounds, to: nil))
            let drag = MockDrag(pasteboard: pasteboard, location: point, window: window)
            let target = Self.windowDragTarget(window, drag)
            var performed = false
            if let destination: any NSDraggingDestination = target {
                let entered = destination.draggingEntered?(drag) ?? []
                let updated = destination.draggingUpdated?(drag) ?? entered
                if !updated.isEmpty, destination.prepareForDragOperation?(drag) ?? true {
                    performed = destination.performDragOperation?(drag) ?? false
                    destination.concludeDragOperation?(drag)
                }
                destination.draggingEnded?(drag)
            }
            await Self.pump(.milliseconds(1200))

            let text = textView.string
            let chips = model.attachments(for: id).count
            let ok = target != nil && performed && text == expectedText && chips == expectedChips
            if !ok { failures += 1 }
            print(
                "DROPTEST \(ok ? "PASS" : "FAIL") \(name) \(payload.rawValue)@\(spot.rawValue): "
                    + "target=\(target.map { "\(type(of: $0))" } ?? "none") performed=\(performed) "
                    + "text=\(text.isEmpty ? "empty" : "\"\(text.prefix(40))\"") chips=\(chips)")
        }

        /// A Finder image attaches without a copy and removing its chip leaves the original; a staged copy (what a
        /// promised screenshot becomes) is deleted with its chip.
        private func checkStagedCopyRemoval(textView: NSTextView, id: ComposerID, model: AppModel, window: NSWindow)
            async
        {
            ran += 1
            let image = scratch.appending(path: "Photo.png")
            let png = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
                .representation(using: .png, properties: [:])
            try? png?.write(to: image)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("drop-test-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.writeObjects([image as NSURL])
            let frame = textView.convert(textView.bounds, to: nil)
            let drag = MockDrag(pasteboard: pasteboard, location: NSPoint(x: frame.midX, y: frame.midY), window: window)
            if let destination: any NSDraggingDestination = Self.windowDragTarget(window, drag) {
                _ = destination.draggingEntered?(drag)
                _ = destination.draggingUpdated?(drag)
                _ = destination.performDragOperation?(drag)
            }
            await Self.pump(.milliseconds(1200))
            guard let chip = model.attachments(for: id).first else {
                failures += 1
                print("DROPTEST FAIL stagedCopy: the image didn't attach")
                return
            }
            let path = URL(fileURLWithPath: String(decoding: chip.bookmark, as: UTF8.self))
            let notCopied = !AttachmentStaging.contains(path, for: id.key.account)
            model.removeAttachment(chip.id, from: id)
            let originalKept = FileManager.default.fileExists(atPath: image.path)

            let account = id.key.account
            var wasStaged = false
            var gone = false
            if let staged = AttachmentStaging.stage(image, for: account) {
                model.addFiles([staged], to: id)
                if let stagedChip = model.attachments(for: id).first {
                    wasStaged = String(decoding: stagedChip.bookmark, as: UTF8.self) == staged.path
                    model.removeAttachment(stagedChip.id, from: id)
                }
                gone = !FileManager.default.fileExists(atPath: staged.path)
            }
            let ok = notCopied && originalKept && wasStaged && gone
            if !ok { failures += 1 }
            print(
                "DROPTEST \(ok ? "PASS" : "FAIL") stagedCopy: finderNotCopied=\(notCopied) "
                    + "originalKept=\(originalKept) staged=\(wasStaged) deletedOnRemove=\(gone)")
        }

        /// Link files are read only when small, and only a web link comes out of one.
        private func checkLinkFiles() {
            ran += 1
            func webloc(_ name: String, url: String, padding: Int) -> URL {
                let file = scratch.appending(path: name)
                let plist: [String: Any] = ["URL": url, "Padding": String(repeating: "x", count: padding)]
                try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: file)
                return file
            }
            let small = DroppedFile.linkFile(webloc("Small.webloc", url: "https://example.com/a", padding: 0))
            let large = DroppedFile.linkFile(webloc("Large.webloc", url: "https://example.com/b", padding: 70_000))
            let local = DroppedFile.linkFile(webloc("Local.webloc", url: "file:///etc/hosts", padding: 0))
            var smallOK = false
            var largeOK = false
            var localOK = false
            if case .link(let url) = small { smallOK = url.absoluteString == "https://example.com/a" }
            if case .unusable = large { largeOK = true }
            if case .unusable = local { localOK = true }
            let ok = smallOK && largeOK && localOK
            if !ok { failures += 1 }
            print(
                "DROPTEST \(ok ? "PASS" : "FAIL") linkFiles: small=\(smallOK) oversizeRefused=\(largeOK) fileRefused=\(localOK)"
            )
        }

        /// Which `DroppedFile` each kind of dragged item becomes. This checks the representation order, not a real
        /// promise delivery.
        private func checkRepresentations() async {
            func data(_ type: String, _ bytes: Data) -> NSItemProvider {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { done in
                    done(bytes, nil)
                    return nil
                }
                return provider
            }
            let rtf = Data("{\\rtf1\\ansi Test}".utf8)
            let png = scratch.appending(path: "Shot.png")
            try? NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
                .representation(using: .png, properties: [:])?.write(to: png)
            let webloc = scratch.appending(path: "Link.webloc")
            try? PropertyListSerialization.data(
                fromPropertyList: ["URL": "https://example.com/a"], format: .xml, options: 0
            ).write(to: webloc)

            let cases: [(String, NSItemProvider, (DroppedFile?) -> Bool)] = [
                ("pdfData", data(UTType.pdf.identifier, Data("%PDF-1.4\n%%EOF\n".utf8)), { $0.isCopy }),
                ("zipData", data(UTType.zip.identifier, Data("PK\u{5}\u{6}".utf8) + Data(count: 18)), { $0.isCopy }),
                ("privateData", data("com.example.drop-test.private", Data([1, 2, 3])), { $0 == nil }),
                ("htmlOnly", data(UTType.html.identifier, Data("<b>Test</b>".utf8)), { $0 == nil }),
                ("plainText", NSItemProvider(object: "Test" as NSString), { $0.text == "Test" }),
                ("rtfOnly", data(UTType.rtf.identifier, rtf), { $0.text == "Test" }),
                ("emptyRTF", data(UTType.rtf.identifier, Data("{\\rtf1 }".utf8)), { $0 == nil }),
                ("malformedRTF", data(UTType.rtf.identifier, Data("not rtf".utf8)), { $0 == nil || $0.text != nil }),
                ("pngFile", NSItemProvider(contentsOf: png) ?? NSItemProvider(), { $0 != nil && $0.text == nil }),
                (
                    "weblocFile", NSItemProvider(contentsOf: webloc) ?? NSItemProvider(),
                    {
                        $0.link == URL(string: "https://example.com/a")
                    }
                ),
            ]
            for (name, provider, expect) in cases {
                ran += 1
                let result = await Self.load(provider)
                let ok = expect(result)
                if !ok { failures += 1 }
                print("DROPTEST \(ok ? "PASS" : "FAIL") representation \(name): \(Self.describe(result))")
                if case .copy(let copy) = result { AttachmentStaging.discard(copy) }
            }

            let textFile = scratch.appending(path: "Notes.txt")
            try? Data("Notes".utf8).write(to: textFile)
            let promise = NSItemProvider()
            promise.registerFileRepresentation(
                forTypeIdentifier: UTType.plainText.identifier, fileOptions: [], visibility: .all
            ) { done in
                done(textFile, false, nil)
                return nil
            }
            let promised = await Self.load(promise)
            print("DROPTEST INFO promised text file becomes \(Self.describe(promised))")
            if case .copy(let copy) = promised { AttachmentStaging.discard(copy) }
        }

        /// A Finder file that also offers its name as text, dropped on the text view. Reported, not counted: whether
        /// it attaches depends on which view AppKit picks.
        private func reportFileWithText(textView: NSTextView, id: ComposerID, model: AppModel, window: NSWindow) async {
            textView.string = ""
            textView.didChangeText()
            for attachment in model.attachments(for: id) { model.removeAttachment(attachment.id, from: id) }
            let file = scratch.appending(path: "Named.pdf")
            try? Data("%PDF-1.4\n%%EOF\n".utf8).write(to: file)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("drop-test-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.writeObjects([file as NSURL])
            pasteboard.addTypes([.string], owner: nil)
            pasteboard.setString("Named.pdf", forType: .string)
            let frame = textView.convert(textView.bounds, to: nil)
            let drag = MockDrag(pasteboard: pasteboard, location: NSPoint(x: frame.midX, y: frame.midY), window: window)
            let target = Self.windowDragTarget(window, drag)
            if let destination: any NSDraggingDestination = target {
                _ = destination.draggingEntered?(drag)
                _ = destination.draggingUpdated?(drag)
                _ = destination.performDragOperation?(drag)
            }
            await Self.pump(.milliseconds(1200))
            let chips = model.attachments(for: id).count
            print(
                "DROPTEST KNOWN fileWithText@textCentre: target=\(target.map { "\(type(of: $0))" } ?? "none") "
                    + "chips=\(chips) text=\(textView.string.isEmpty ? "empty" : "\"\(textView.string)\"")")
            for attachment in model.attachments(for: id) { model.removeAttachment(attachment.id, from: id) }
            textView.string = ""
            textView.didChangeText()
        }

        /// Text dropped for a composer that isn't on screen waits for it, and is delivered once when it shows; a
        /// second identical drop is typed in again.
        private func checkDroppedTextQueue(current: SpaceKey, model: AppModel, window: NSWindow) async {
            ran += 1
            guard let other = model.inbox.first(where: { $0.id != current })?.id else {
                failures += 1
                print("DROPTEST FAIL droppedTextQueue: no second space")
                return
            }
            let hidden = ComposerID(key: other, thread: nil)
            _ = model.addDroppedFiles([.text("Queued")], to: hidden)
            await Self.pump(.milliseconds(500))
            let waited = model.droppedText[hidden] == ["Queued"]

            model.select(other)
            await Self.pump(.seconds(2))
            let editor = Self.textViews(in: window).filter(\.isEditable).min {
                $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
            }
            let delivered = model.droppedText[hidden] == nil && editor?.string.contains("Queued") == true

            editor?.string = ""
            editor?.didChangeText()
            await Self.pump(.milliseconds(300))
            for _ in 0..<2 {
                _ = model.addDroppedFiles([.text("Twice")], to: hidden)
                await Self.pump(.milliseconds(500))
            }
            let twice = editor?.string.components(separatedBy: "Twice").count == 3
            let ok = waited && delivered && twice
            if !ok { failures += 1 }
            print(
                "DROPTEST \(ok ? "PASS" : "FAIL") droppedTextQueue: waited=\(waited) deliveredOnShow=\(delivered) "
                    + "identicalTwice=\(twice)")
        }

        private static func load(_ provider: NSItemProvider) async -> DroppedFile? {
            await withCheckedContinuation { continuation in
                _ = provider.loadTransferable(type: DroppedFile.self) { continuation.resume(returning: try? $0.get()) }
            }
        }

        private static func describe(_ drop: DroppedFile?) -> String {
            switch drop {
            case nil: "refused"
            case .link(let url): "link(\(url.isFileURL ? url.lastPathComponent : url.absoluteString))"
            case .text(let text): "text(\"\(text.prefix(40))\")"
            case .copy(let url): "copy(\(url.lastPathComponent))"
            case .tooLarge(let name): "tooLarge(\(name))"
            case .unusable(let name): "unusable(\(name))"
            }
        }

        /// AppKit's window routing: the view a real drag with this info would be delivered to.
        private static func windowDragTarget(_ window: NSWindow, _ drag: any NSDraggingInfo) -> NSView? {
            let selector = NSSelectorFromString("_findDragTargetFrom:")
            guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return nil }
            typealias Find = @convention(c) (NSWindow, Selector, AnyObject) -> AnyObject?
            let find = unsafeBitCast(method_getImplementation(method), to: Find.self)
            return find(window, selector, drag as AnyObject) as? NSView
        }

        private static func textViews(in window: NSWindow) -> [NSTextView] {
            var found: [NSTextView] = []
            func walk(_ view: NSView) {
                if let textView = view as? NSTextView { found.append(textView) }
                for subview in view.subviews { walk(subview) }
            }
            window.contentView.map(walk)
            return found
        }

        private static func spinOnce() {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }

        private static func pump(_ duration: Duration) async {
            let end = ContinuousClock.now + duration
            while ContinuousClock.now < end {
                spinOnce()
                await Task.yield()
            }
        }

        private static func settle(_ model: AppModel) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline, model.inbox.isEmpty {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return !model.inbox.isEmpty
        }
    }

    extension Optional where Wrapped == DroppedFile {
        fileprivate var isCopy: Bool { if case .copy = self { true } else { false } }
        fileprivate var text: String? { if case .text(let text) = self { text } else { nil } }
        fileprivate var link: URL? { if case .link(let url) = self { url } else { nil } }
    }

    /// The parts of `NSDraggingInfo` that drag destinations read.
    private final class MockDrag: NSObject, NSDraggingInfo {
        let pasteboard: NSPasteboard
        let location: NSPoint
        weak var window: NSWindow?

        init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow?) {
            self.pasteboard = pasteboard
            self.location = location
            self.window = window
        }

        var draggingDestinationWindow: NSWindow? { window }
        var draggingSourceOperationMask: NSDragOperation { [.copy, .generic, .move] }
        var draggingLocation: NSPoint { location }
        var draggedImageLocation: NSPoint { location }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { pasteboard }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 7 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }
#endif
