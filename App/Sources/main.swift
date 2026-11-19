import Foundation

#if DEBUG
    if let index = CommandLine.arguments.firstIndex(of: "--keychain-probe") {
        let mode = CommandLine.arguments.dropFirst(index + 1).first ?? ""
        exit(await ProbeCommand.run(mode: mode))
    }
    if let index = CommandLine.arguments.firstIndex(of: "--snapshot") {
        let directory = CommandLine.arguments.dropFirst(index + 1).first ?? "build/snapshots"
        exit(await SnapshotCommand.run(directory: directory))
    }
    if CommandLine.arguments.contains("--drop-test") {
        exit(await DropTestCommand.run())
    }
#endif

GChatApp.main()
