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
let strict: [SwiftSetting] = [.swiftLanguageMode(.v6), .unsafeFlags(["-warnings-as-errors"], .when(platforms: [.linux]))]

/// The client's host services, built on their own here, on Linux's CI
/// (`swift build --target VisorServices`): a file that uses Foundation
/// without importing it fails here as it does in Visor on Isomer (the web,
/// Android), not only there. On Apple's systems another module's Foundation
/// leaks into the lookup and hides it.
let services: [Target] = [
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
    // swift-crypto: HMAC-SHA256 for the agents' tokens (JWT), SHA-256 for
    // the admin token's hash.
    .target(name: "VisorServer",
            dependencies: ["VisorProtocol", "ClaudeTranscript", "MessageCache", "AgentHostWire", "VisorSystem", "VisorAgent",
                           .product(name: "Crypto", package: "swift-crypto")],
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
let proxyPackages: [Package.Dependency] = []
#else
#if os(Linux)
/// relay-client, inside a relayed container (netlink, nftables,
/// SO_ORIGINAL_DST: Linux alone): visor-server run by that name (a link to
/// it, tools/linux_programs.sh), so its runtime, Foundation, NIO and
/// BoringSSL are visor-server's, not a second copy.
let relayClient: [Target] = [
    .target(name: "CRelayClientPOSIX", path: "libraries/visor_agent_proxy/relay_c"),
    .target(name: "VisorRelayClient", dependencies: ["VisorAgentProxy", "CRelayClientPOSIX"],
            path: "libraries/visor_agent_proxy/RelayClient", swiftSettings: strict),
]
let relayClientDependency: [Target.Dependency] = ["VisorRelayClient"]
#else
let relayClient: [Target] = []
let relayClientDependency: [Target.Dependency] = []
#endif
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
            dependencies: ["VisorServer", "VisorAgent", "VisorMCPBridge", "VisorProtocol", "VisorSystem",
                           .product(name: "AgentProtocol", package: "agent_protocol"),
                           .product(name: "GRPCCore", package: "grpc-swift-2"),
                           .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport")],
            path: "libraries/visor_driver/Sources", swiftSettings: strict),
    .target(name: "VisorNativeRunner",
            dependencies: ["VisorSystem", .product(name: "AgentProtocol", package: "agent_protocol"),
                           .product(name: "GRPCCore", package: "grpc-swift-2"),
                           .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport")],
            path: "libraries/visor_native_runner/Sources", swiftSettings: strict),
    // Visor's agent-proxy (docs/agent-proxy.md): its sockets, the proxy, and
    // its host, which visor-server runs inside itself when `agentProxy` is
    // set. SwiftNIO, NIOSSL, swift-certificates, swift-asn1 and swift-crypto.
    .target(name: "CAgentProxyPOSIX", path: "libraries/visor_agent_proxy/c"),
    .target(name: "VisorAgentProxy",
            dependencies: ["CAgentProxyPOSIX",
                           .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"),
                           .product(name: "NIOHTTP1", package: "swift-nio"), .product(name: "NIOSSL", package: "swift-nio-ssl"),
                           .product(name: "X509", package: "swift-certificates"), .product(name: "SwiftASN1", package: "swift-asn1"),
                           .product(name: "Crypto", package: "swift-crypto"), .product(name: "_CryptoExtras", package: "swift-crypto")],
            path: "libraries/visor_agent_proxy/Sources", swiftSettings: strict),
    .target(name: "VisorAgentProxyHost",
            dependencies: ["VisorAgentProxy", "VisorServer", .product(name: "Crypto", package: "swift-crypto")],
            path: "libraries/visor_agent_proxy/Host", swiftSettings: strict),
    .executableTarget(name: "VisorServerMain",
                      dependencies: ["VisorServerCLI", "VisorServerLinux", "VisorAgentHost", "VisorMCPBridge", "VisorDriver", "VisorNativeRunner",
                                     "VisorAgentProxyHost"] + relayClientDependency,
                      path: "applications/visor_server_linux", exclude: ["BUILD.bazel"], swiftSettings: strict),
] + relayClient
/// The tests are Bazel's swift_test targets (//tests:linux), not SwiftPM's.
let tests: [Target] = []
/// The agents' host, built with the server: `swift build -c release` puts
/// both in the same folder, where the server looks for it.
let agentHost: [Product] = [.executable(name: "visor-agent-host", targets: ["VisorAgentHostMain"])]
/// agent_protocol (its driver, dispatcher and wrapper), by release, and its
/// gRPC.
let runnerPackages: [Package.Dependency] = [
    // As third_party/swift_packages pins it.
    .package(url: "https://github.com/AttilaTheFun/agent_protocol.git", exact: "0.5.0"),
    .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.4"),
    .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.12.0"),
]
/// agent-proxy's: the versions third_party/swift_packages resolves for Bazel.
let proxyPackages: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.6"),
    .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.1"),
    .package(url: "https://github.com/apple/swift-asn1.git", from: "1.7.3"),
]
#endif

let package = Package(
    name: "visor",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.executable(name: "visor-server", targets: ["VisorServerMain"])] + agentHost,
    // swift_sql at its release, as third_party/swift_packages pins it; and
    // swift-crypto at the version its graph resolves.
    dependencies: [.package(url: "https://github.com/AttilaTheFun/swift_sql.git", exact: "0.35.0"),
                   .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.2")] + runnerPackages + proxyPackages,
    targets: services + shared + system + tests
)
