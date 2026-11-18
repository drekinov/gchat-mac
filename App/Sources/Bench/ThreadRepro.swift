import AppKit
import ChatModel
import Foundation

/// `--fake --repro-thread`: opens and closes threads across spaces and window widths, printing progress, so layout
/// crashes around the thread inspector reproduce without clicking.
@MainActor
struct ThreadRepro {
    let model: AppModel

    func run() async {
        setlinebuf(stdout)
        NSApplication.shared.activate()
        try? await Task.sleep(for: .seconds(4))
        let widths: [Double] = [860, 1000, 1500, 900]
        var step = 0
        for width in widths {
            if let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                var frame = window.frame
                frame.size.width = width
                window.setFrame(frame, display: true, animate: false)
            }
            for entry in model.inbox.prefix(12) where model.isThreaded(entry.id) {
                model.select(entry.id)
                try? await Task.sleep(for: .seconds(1.5))
                guard let thread = model.openMessages.compactMap(\.thread).last else { continue }
                model.openThread(thread)
                try? await Task.sleep(for: .seconds(1.5))
                step += 1
                print("REPRO step=\(step) width=\(Int(width)) opened thread")
                model.closeThread()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        print("REPRO done steps=\(step)")
        NSApplication.shared.terminate(nil)
    }
}
