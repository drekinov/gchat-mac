#if DEBUG
    import SwiftUI

    struct DebugCommands: Commands {
        @Environment(\.openWindow) private var openWindow

        var body: some Commands {
            CommandMenu("Debug") {
                Button("Footprint") { openWindow(id: "footprint") }
                    .keyboardShortcut("f", modifiers: [.command, .option])
            }
        }
    }

    struct FootprintPanel: View {
        let model: AppModel

        var body: some View {
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let megabytes = Footprint.megabytes() ?? 0
                VStack(alignment: .leading, spacing: 12) {
                    Text("phys_footprint").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.1f MB", megabytes))
                        .font(.system(size: 34, weight: .medium, design: .monospaced))
                    ProgressView(value: min(megabytes, 150), total: 150)
                    Text("Budget: 150 MB resident").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ForEach(model.accounts) { info in
                        HStack {
                            AccountChip(info: info)
                            Spacer()
                            Text(model.status(info.id).label).font(.callout)
                            Text("\(model.snapshots[info.id]?.spaces.count ?? 0) spaces")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Open space: \(model.openMessages.count) messages in memory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
#endif
