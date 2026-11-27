// swift-tools-version: 6.4
import PackageDescription

let sharedSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

func module(
    _ name: String,
    dependencies: [Target.Dependency] = [],
    linkerSettings: [LinkerSetting] = []
) -> Target {
    .target(
        name: name,
        dependencies: dependencies,
        swiftSettings: sharedSettings,
        linkerSettings: linkerSettings
    )
}

let package = Package(
    name: "gchat-mac",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Diagnostics", targets: ["Diagnostics"]),
        .library(name: "ChatModel", targets: ["ChatModel"]),
        .library(name: "ChatKeychain", targets: ["ChatKeychain"]),
        .library(name: "ChatText", targets: ["ChatText"]),
        .library(name: "GoogleChat", targets: ["GoogleChat"]),
        .library(name: "FakeChatServer", targets: ["FakeChatServer"]),
        .library(name: "ChatAuth", targets: ["ChatAuth"]),
        .library(name: "ChatStore", targets: ["ChatStore"]),
        .library(name: "ChatNet", targets: ["ChatNet"]),
        .library(name: "ChatSync", targets: ["ChatSync"]),
    ],
    targets: [
        module("Diagnostics"),
        module("ChatModel"),
        module("ChatKeychain"),
        module("ChatText", dependencies: ["ChatModel"]),
        module("GoogleChat", dependencies: ["ChatModel", "ChatNet", "Diagnostics"]),
        module("FakeChatServer", dependencies: ["ChatModel", "ChatNet"]),
        module("ChatAuth", dependencies: ["ChatKeychain", "ChatModel", "ChatNet", "GoogleChat", "Diagnostics"]),
        module(
            "ChatStore",
            dependencies: ["ChatKeychain", "ChatModel", "Diagnostics"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        module("ChatNet", dependencies: ["ChatModel", "Diagnostics"]),
        module(
            "ChatSync",
            dependencies: ["ChatModel", "Diagnostics", "GoogleChat", "ChatAuth", "ChatStore", "ChatNet"]
        ),
        .testTarget(
            name: "ChatKeychainTests",
            dependencies: ["ChatKeychain"],
            swiftSettings: sharedSettings
        ),
        .testTarget(
            name: "ChatAuthTests",
            dependencies: ["ChatAuth", "ChatKeychain", "ChatModel", "ChatNet", "GoogleChat"],
            swiftSettings: sharedSettings
        ),
        .testTarget(
            name: "ChatStoreTests",
            dependencies: ["ChatStore", "ChatKeychain", "ChatModel"],
            swiftSettings: sharedSettings
        ),
        .testTarget(
            name: "ChatSyncTests",
            dependencies: ["ChatSync", "FakeChatServer", "GoogleChat", "ChatStore", "ChatModel", "ChatKeychain"],
            swiftSettings: sharedSettings
        ),
        .testTarget(
            name: "ChatModelTests",
            dependencies: ["ChatModel"],
            swiftSettings: sharedSettings
        ),
        .testTarget(
            name: "ChatTextTests",
            dependencies: ["ChatText", "ChatModel"],
            swiftSettings: sharedSettings
        ),
        .testTarget(
            name: "ChatNetTests",
            dependencies: ["ChatNet"],
            swiftSettings: sharedSettings
        ),
        .testTarget(
            name: "GoogleChatTests",
            dependencies: ["GoogleChat", "FakeChatServer", "ChatNet", "ChatModel"],
            resources: [.copy("Fixtures")],
            swiftSettings: sharedSettings
        ),
        .testTarget(
            name: "FakeChatServerTests",
            dependencies: ["FakeChatServer", "ChatModel"],
            swiftSettings: sharedSettings
        ),
    ]
)
