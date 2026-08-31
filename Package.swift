// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HiveChat",
    platforms: [
        /* iOS 17 is the floor. iOS 16 worked until HiveChatUI wanted the
           modern zero-parameter `onChange`, whose predecessor is deprecated
           from 17 — and carrying a deprecated call to keep a four-year-old OS
           puts warnings in every consumer's build that they cannot fix. The
           core target touches no SwiftUI and would run happily on iOS 13, so
           an app on an older floor can depend on `HiveChat` alone, or pin
           0.1.x which supported iOS 16.

           tvOS and watchOS are deliberately not claimed. Nothing here is
           designed for a remote or a 45mm screen, and claiming a platform
           the UI has never been laid out for is a promise this package
           cannot keep. */
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        /* Two products on purpose. An app with its own design system takes
           HiveChat alone and binds to the published state; an app that wants
           a chat screen in an afternoon takes HiveChatUI, which depends on
           the core. Nobody is forced to link SwiftUI to send a message. */
        .library(name: "HiveChat", targets: ["HiveChat"]),
        .library(name: "HiveChatUI", targets: ["HiveChatUI"]),
    ],
    targets: [
        .target(name: "HiveChat"),
        .target(name: "HiveChatUI", dependencies: ["HiveChat"]),
        .testTarget(name: "HiveChatTests", dependencies: ["HiveChat"]),
    ]
)
