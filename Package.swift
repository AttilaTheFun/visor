// swift-tools-version:6.0
// The command-line Visor server for Linux and Windows, built with SwiftPM
// from the same libraries Bazel builds the Mac's apps from:
//
//   swift build -c release --product visor-server
//
// The server library (libraries/visor_server) is the same everywhere and
// asks nothing of the system except through what it is given. The system
// is chosen here, once: the executable built on Linux gives it Linux's
// (libraries/visor_server_linux), the one built on Windows gives it
// Windows's (libraries/visor_server_windows). The Mac's apps and the iOS
// app are Bazel's (MODULE.bazel); this builds none of them.

import PackageDescription

/// Swift 6, and a warning is an error, as in the Bazel build (STRICT_SWIFT)
/// — except on Windows, whose SDK module warns about itself ("wchar_t …
/// broken by a context change") in everything that imports Foundation.
let strict: [SwiftSetting] = [.swiftLanguageMode(.v6), .unsafeFlags(["-warnings-as-errors"], .when(platforms: [.macOS, .linux]))]

/// The libraries every system's server is built from.
let shared: [Target] = [
    .target(name: "VisorProtocol", path: "libraries/visor_protocol/Sources", swiftSettings: strict),
    .target(name: "ClaudeTranscript", path: "libraries/claude_transcript/Sources", swiftSettings: strict),
    .target(
        name: "MessageCache",
        dependencies: [
            "VisorProtocol",
            .product(name: "SQLite", package: "SQLite.swift", condition: .when(platforms: [.macOS, .linux])),
        ],
        path: "libraries/message_cache/Sources",
        // Where there is no SQLite (Windows), the cache is kept in memory.
        swiftSettings: strict + [.define("MESSAGE_CACHE_SQLITE", .when(platforms: [.macOS, .linux]))]
    ),
    .target(name: "VisorServer", dependencies: ["VisorProtocol", "ClaudeTranscript", "MessageCache"],
            path: "libraries/visor_server/Sources", swiftSettings: strict),
    .target(name: "VisorServerCLI", dependencies: ["VisorServer", "VisorProtocol"],
            path: "libraries/visor_server_cli/Sources", swiftSettings: strict),
]

#if os(Windows)
/// Windows: Winsock, ConPTY, the Win32 process calls.
let system: [Target] = [
    .target(name: "VisorServerWindows", dependencies: ["ClaudeTranscript", "VisorServer", "VisorServerCLI"],
            path: "libraries/visor_server_windows/Sources", swiftSettings: strict),
    .executableTarget(name: "VisorServerMain", dependencies: ["VisorServerCLI", "VisorServerWindows"],
                      path: "applications/visor_server_windows", swiftSettings: strict),
]
let tests: [Target] = []
#else
/// Linux: POSIX terminals, signals and sockets (shared with the Mac).
let system: [Target] = [
    .target(name: "CVisorPOSIX", path: "libraries/visor_server_posix/c"),
    .target(name: "VisorServerPOSIX", dependencies: ["CVisorPOSIX", "VisorServer"],
            path: "libraries/visor_server_posix/Sources", swiftSettings: strict),
    .target(name: "VisorSSH", dependencies: [.product(name: "NIOSSH", package: "swift-nio-ssh")],
            path: "libraries/visor_ssh/Sources", swiftSettings: strict),
    .target(name: "VisorServerSSH", dependencies: ["VisorServer", "VisorSSH"],
            path: "libraries/visor_server_ssh/Sources", swiftSettings: strict),
    .target(name: "VisorServerLinux", dependencies: ["ClaudeTranscript", "VisorServer", "VisorServerCLI", "VisorServerPOSIX", "VisorServerSSH"],
            path: "libraries/visor_server_linux/Sources", swiftSettings: strict),
    .executableTarget(name: "VisorServerMain", dependencies: ["VisorServerCLI", "VisorServerLinux"],
                      path: "applications/visor_server_linux", swiftSettings: strict),
]
/// The server's tests, on Linux's platform (tests/visor_server_tests/linux).
let tests: [Target] = [
    .testTarget(name: "VisorServerTests",
                dependencies: ["VisorServer", "VisorProtocol", "ClaudeTranscript", "MessageCache", "VisorServerCLI", "VisorServerLinux"],
                path: "tests/visor_server_tests", exclude: ["apple", "BUILD.bazel"], swiftSettings: strict),
]
#endif

let package = Package(
    name: "visor",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "visor-server", targets: ["VisorServerMain"])],
    dependencies: [
        // The message cache, where there is SQLite to keep it in.
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", exact: "0.15.3"),
        // SSH to peers (the server's own key, the peer's socket file).
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
    ],
    targets: shared + system + tests
)
