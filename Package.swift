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
//
// It also offers Visor's client as libraries, for an app that has a Visor
// of its own (Shireworks' Visor tab: issues#4): VisorClient, VisorUI (with
// VisorView, the whole of it in one view) and VisorServices, for iOS and
// macOS on Apple's SwiftUI. They are declared on every host, as an app's
// Apple builds may resolve packages on Linux (rules_applecross), and built
// only for Apple's platforms. The client on Isomer (the web, Android) stays
// Bazel's.

import PackageDescription

/// Visor's own server builds leave the client out, which builds only against
/// Apple's SwiftUI: CI's Linux SwiftPM steps and the agent image set
/// VISOR_SERVER_ONLY=1, since `swift test` and `--target` build what the
/// package declares. Windows leaves it out always.
let serverOnly = Context.environment["VISOR_SERVER_ONLY"] != nil
#if os(Windows)
let withClient = false
#else
let withClient = !serverOnly
#endif

/// Swift 6, and a warning is an error, as in the Bazel build (STRICT_SWIFT)
/// — except on Windows, whose SDK module warns about itself ("wchar_t …
/// broken by a context change") in everything that imports Foundation.
///
/// Where the client is declared, the language mode alone: a product built
/// with unsafe flags can't be another package's dependency (the client
/// libraries below), and the apps' builds are Bazel's, which holds them to
/// STRICT_SWIFT. Visor's own Linux builds (VISOR_SERVER_ONLY) keep warnings
/// as errors.
let strict: [SwiftSetting] = withClient
    ? [.swiftLanguageMode(.v6)]
    : [.swiftLanguageMode(.v6), .unsafeFlags(["-warnings-as-errors"], .when(platforms: [.linux]))]

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
    // What the server and the agents' code below it share (the tools,
    // processes, folders, this computer), with a SystemPlatform of its own.
    .target(name: "VisorSystem", dependencies: ["ClaudeTranscript", "VisorProtocol"],
            path: "libraries/visor_system/Sources", swiftSettings: strict),
    // The agents' code, between the two: the process layer that starts,
    // talks to and stops Claude Code and Codex, and the harnesses, logs,
    // transcripts and catalogs of their sessions.
    .target(name: "VisorAgent", dependencies: ["AgentHostWire", "ClaudeTranscript", "MessageCache", "VisorProtocol", "VisorSystem"],
            path: "libraries/visor_agent/Sources", swiftSettings: strict),
    .target(name: "VisorServer",
            dependencies: ["VisorProtocol", "ClaudeTranscript", "MessageCache", "AgentHostWire", "VisorSystem", "VisorAgent"],
            path: "libraries/visor_server/Sources", swiftSettings: strict),
    .target(name: "VisorServerCLI", dependencies: ["VisorServer", "VisorProtocol", "VisorSystem"],
            path: "libraries/visor_server_cli/Sources", swiftSettings: strict),
]

#if os(Windows)
/// Windows: Winsock, the Win32 process calls.
let system: [Target] = [
    .target(name: "VisorServerWindows", dependencies: ["ClaudeTranscript", "VisorServer", "VisorServerCLI", "VisorSystem"],
            path: "libraries/visor_server_windows/Sources", swiftSettings: strict),
    .executableTarget(name: "VisorServerMain", dependencies: ["VisorServerCLI", "VisorServerWindows"],
                      path: "applications/visor_server_windows", swiftSettings: strict),
]
let tests: [Target] = []
let agentHost: [Product] = []
let runnerPackages: [Package.Dependency] = []
#else
/// Linux: POSIX signals and sockets (shared with the Mac), and the agents'
/// host, built beside the server.
let system: [Target] = [
    .target(name: "CVisorPOSIX", path: "libraries/visor_server_posix/c"),
    .target(name: "VisorAgentHost", dependencies: ["AgentHostWire", "CVisorPOSIX"],
            path: "libraries/visor_agent_host/Sources", swiftSettings: strict),
    .target(name: "VisorMCPBridge", dependencies: ["VisorProtocol", "CVisorPOSIX"],
            path: "libraries/visor_mcp_bridge/Sources", swiftSettings: strict),
    .executableTarget(name: "VisorAgentHostMain", dependencies: ["VisorAgentHost", "VisorMCPBridge"],
                      path: "applications/visor_agent_host", exclude: ["BUILD.bazel"], swiftSettings: strict),
    .target(name: "VisorServerPOSIX", dependencies: ["CVisorPOSIX", "VisorServer", "VisorSystem"],
            path: "libraries/visor_server_posix/Sources", swiftSettings: strict),
    .target(name: "VisorServerLinux",
            dependencies: ["ClaudeTranscript", "VisorServer", "VisorServerCLI", "VisorServerPOSIX", "VisorSystem"],
            path: "libraries/visor_server_linux/Sources", swiftSettings: strict),
    // agent_protocol's driver and dispatcher (gRPC), and the native runner
    // that pulls from a dispatcher and runs agent-wrapper: on Linux and the
    // Mac, never Windows (the server library itself has neither).
    .target(name: "VisorDriver",
            dependencies: ["VisorServer", "VisorAgent", "VisorProtocol",
                           .product(name: "AgentProtocol", package: "agent_protocol"),
                           .product(name: "GRPCCore", package: "grpc-swift-2"),
                           .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport")],
            path: "libraries/visor_driver/Sources", swiftSettings: strict),
    .target(name: "VisorNativeRunner",
            dependencies: [.product(name: "AgentProtocol", package: "agent_protocol"),
                           .product(name: "GRPCCore", package: "grpc-swift-2"),
                           .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport")],
            path: "libraries/visor_native_runner/Sources", swiftSettings: strict),
    .executableTarget(name: "VisorServerMain",
                      dependencies: ["VisorServerCLI", "VisorServerLinux", "VisorAgentHost", "VisorMCPBridge", "VisorDriver", "VisorNativeRunner"],
                      path: "applications/visor_server_linux", exclude: ["BUILD.bazel"], swiftSettings: strict),
    // Visor Runner's MCP proxy and its commands; its agent built here too,
    // for a Mac without Bazel's output for it (`swift build -c release
    // --product visor-runner-agent`).
    // Its GitHub proxy's authority (RunnerCA) is swift-certificates'; the
    // proxy opens GitHub's hosts with SwiftNIO and swift-nio-ssl.
    .target(name: "VisorRunner",
            dependencies: ["CVisorPOSIX", .product(name: "X509", package: "swift-certificates"),
                           .product(name: "Crypto", package: "swift-crypto"), .product(name: "SwiftASN1", package: "swift-asn1"),
                           .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"),
                           .product(name: "NIOHTTP1", package: "swift-nio"), .product(name: "NIOSSL", package: "swift-nio-ssl"),
                           .product(name: "_CryptoExtras", package: "swift-crypto")],
            path: "libraries/visor_runner/Sources", swiftSettings: strict),
    .executableTarget(name: "VisorRunnerAgentMain", dependencies: ["VisorRunner"],
                      path: "applications/visor_runner_agent", exclude: ["BUILD.bazel"], swiftSettings: strict),
]
/// The tests are Bazel's swift_test targets (//tests:linux), not SwiftPM's.
let tests: [Target] = []
/// The agents' host, built with the server: `swift build -c release` puts
/// both in the same folder, where the server looks for it.
let agentHost: [Product] = [.executable(name: "visor-agent-host", targets: ["VisorAgentHostMain"]),
                            .executable(name: "visor-runner-agent", targets: ["VisorRunnerAgentMain"])]
/// The Runner's packages: X509 and its cryptography, at the versions
/// third_party/swift_packages pins.
let runnerPackages: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.1"),
    // 3.x too: the client's SSH takes it, and an app that embeds the client
    // may hold it there (Apple's containerization 0.33 allows 3.x alone).
    // The Runner's own builds resolve 4.x (Package.resolved). The Runner
    // takes `_CryptoExtras`, the name both have (4.x's re-exports its
    // CryptoExtras): a package's every target must resolve, used or not.
    .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    .package(url: "https://github.com/apple/swift-asn1.git", from: "1.7.3"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.6"),
    // agent_protocol (its driver, dispatcher and wrapper), by release, and
    // its gRPC.
    .package(url: "https://github.com/AttilaTheFun/agent_protocol.git", from: "0.2.0"),
    .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.4"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.12.0"),
]
#endif

/// Visor's client for Apple's platforms, as libraries: what the Bazel build
/// compiles for the iPhone and the Mac (visor_client, visor_ui and
/// visor_services with its native services), on AgentUI, at the versions
/// third_party/swift_packages pins. Declared on every host but Windows,
/// unless VISOR_SERVER_ONLY (above); built only for Apple's platforms.
let client: [Target] = !withClient ? [] : [
    .target(name: "VisorSSH",
            dependencies: [.product(name: "NIOSSH", package: "swift-nio-ssh"), .product(name: "NIOCore", package: "swift-nio"),
                           .product(name: "NIOPosix", package: "swift-nio"), .product(name: "Crypto", package: "swift-crypto")],
            path: "libraries/visor_ssh/Sources", swiftSettings: strict),
    .target(name: "VisorPasteboard", path: "libraries/visor_pasteboard/Sources", swiftSettings: strict),
    .target(name: "VisorCamera", path: "libraries/visor_camera/Sources", swiftSettings: strict),
    .target(name: "VisorClient", dependencies: ["MessageCache", "VisorProtocol", "VisorServices"],
            path: "libraries/visor_client/Sources", swiftSettings: strict),
    .target(name: "VisorUI",
            dependencies: ["VisorCamera", "VisorPasteboard", "VisorClient", "VisorProtocol", "VisorServices", "MessageCache",
                           .product(name: "AgentUI", package: "agent_ui"), .product(name: "NavigationUI", package: "agent_ui")],
            path: "libraries/visor_ui/Sources", swiftSettings: strict),
]
/// The client's host services with their native ones (the sockets, HTTP,
/// settings, notifications, SSH), as Bazel compiles them for Apple's
/// platforms: one module, both folders. Without the client, the shared
/// folder alone (clientServices, above).
let services: [Target] = !withClient ? clientServices : [
    .target(name: "VisorServices", dependencies: ["VisorSSH"], path: "libraries/visor_services",
            exclude: ["BUILD.bazel"], sources: ["Sources", "native"], swiftSettings: strict),
]
let clientProducts: [Product] = !withClient ? [] : [
    .library(name: "VisorClient", targets: ["VisorClient"]),
    .library(name: "VisorUI", targets: ["VisorUI"]),
    .library(name: "VisorServices", targets: ["VisorServices"]),
]
let clientPackages: [Package.Dependency] = !withClient ? [] : [
    .package(url: "https://github.com/AttilaTheFun/agent_ui.git", exact: "0.50.0"),
    .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.15.0"),
]

let package = Package(
    name: "visor",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.executable(name: "visor-server", targets: ["VisorServerMain"])] + agentHost + clientProducts,
    // swift_sql at its release, as third_party/swift_packages pins it.
    dependencies: [.package(url: "https://github.com/AttilaTheFun/swift_sql.git", exact: "0.35.0")] + runnerPackages + clientPackages,
    targets: services + shared + system + tests + client
)
