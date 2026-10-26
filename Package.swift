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

/// The client's host services, built on their own here, on Linux's CI
/// (`swift build --target VisorServices`): a file that uses Foundation
/// without importing it fails here as it does in Visor on Isomer (the web,
/// Android), not only there. On Apple's systems another module's Foundation
/// leaks into the lookup and hides it.
let clientServices: [Target] = [
    .target(name: "VisorServices", path: "libraries/visor_services/Sources", swiftSettings: strict),
]

/// The libraries every system's server is built from.
let shared: [Target] = [
    .target(name: "VisorProtocol", path: "libraries/visor_protocol/Sources", swiftSettings: strict),
    .target(name: "ClaudeTranscript", path: "libraries/claude_transcript/Sources", swiftSettings: strict),
    .target(
        name: "MessageCache",
        dependencies: [
            "VisorProtocol",
            // SQLite (swift_sql, as in the Bazel build) on every system.
            .product(name: "SwiftSQL", package: "swift_sql"),
        ],
        path: "libraries/message_cache/Sources",
        swiftSettings: strict
    ),
    .target(name: "AgentHostWire", path: "libraries/agent_host_wire/Sources", swiftSettings: strict),
    .target(name: "VisorServer",
            dependencies: ["VisorProtocol", "ClaudeTranscript", "MessageCache", "AgentHostWire",
                           // oss's client: the machines sessions lease.
                           .product(name: "OSSClient", package: "oss")],
            path: "libraries/visor_server/Sources", swiftSettings: strict),
    .target(name: "VisorServerCLI", dependencies: ["VisorServer", "VisorProtocol"],
            path: "libraries/visor_server_cli/Sources", swiftSettings: strict),
]

#if os(Windows)
/// Windows: Winsock, the Win32 process calls.
let system: [Target] = [
    .target(name: "VisorServerWindows", dependencies: ["ClaudeTranscript", "VisorServer", "VisorServerCLI"],
            path: "libraries/visor_server_windows/Sources", swiftSettings: strict),
    .executableTarget(name: "VisorServerMain", dependencies: ["VisorServerCLI", "VisorServerWindows"],
                      path: "applications/visor_server_windows", swiftSettings: strict),
]
let tests: [Target] = []
let agentHost: [Product] = []
#else
/// Linux: POSIX signals and sockets (shared with the Mac), and the agents'
/// host, built beside the server.
let system: [Target] = [
    .target(name: "CVisorPOSIX", path: "libraries/visor_server_posix/c"),
    .target(name: "VisorAgentHost", dependencies: ["AgentHostWire", "CVisorPOSIX"],
            path: "libraries/visor_agent_host/Sources", swiftSettings: strict),
    .executableTarget(name: "VisorAgentHostMain", dependencies: ["VisorAgentHost"],
                      path: "applications/visor_agent_host", exclude: ["BUILD.bazel"], swiftSettings: strict),
    .target(name: "VisorServerPOSIX", dependencies: ["CVisorPOSIX", "VisorServer"],
            path: "libraries/visor_server_posix/Sources", swiftSettings: strict),
    .target(name: "VisorServerLinux", dependencies: ["ClaudeTranscript", "VisorServer", "VisorServerCLI", "VisorServerPOSIX"],
            path: "libraries/visor_server_linux/Sources", swiftSettings: strict),
    .executableTarget(name: "VisorServerMain", dependencies: ["VisorServerCLI", "VisorServerLinux"],
                      path: "applications/visor_server_linux", swiftSettings: strict),
]
/// The server's tests, on Linux's platform (tests/visor_server_tests/linux).
let tests: [Target] = [
    .testTarget(name: "VisorServerTests",
                dependencies: ["VisorServer", "VisorProtocol", "ClaudeTranscript", "MessageCache", "VisorServerCLI", "VisorServerLinux",
                               .product(name: "OSSClient", package: "oss")],
                path: "tests/visor_server_tests", exclude: ["apple", "BUILD.bazel"], swiftSettings: strict),
]
/// The agents' host, built with the server: `swift build -c release` puts
/// both in the same folder, where the server looks for it.
let agentHost: [Product] = [.executable(name: "visor-agent-host", targets: ["VisorAgentHostMain"])]
#endif

let package = Package(
    name: "visor",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "visor-server", targets: ["VisorServerMain"])] + agentHost,
    // swift_sql and oss at their releases, as third_party/swift_packages pins them.
    dependencies: [.package(url: "https://github.com/AttilaTheFun/swift_sql.git", exact: "0.35.0"),
                   .package(url: "https://github.com/AttilaTheFun/oss.git", exact: "0.8.0")],
    targets: clientServices + shared + system + tests
)
