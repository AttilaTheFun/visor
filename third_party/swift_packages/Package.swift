// swift-tools-version: 5.9

// The SwiftPM dependencies Visor consumes through rules_swift_package_manager:
// AgentUI (the agent chat page and the navigation containers), swift-nio-ssh,
// swift_sql (SQLite for the message cache, on every host). rspm reads
// Package.resolved for the pinned graph and generates one `@swiftpkg_<name>`
// repo per package.
import PackageDescription

let package = Package(
    name: "visor_swift_packages",
    platforms: [.iOS("18.0"), .macOS("15.0")],
    dependencies: [
        // Isomer's Swift (Foundation and SwiftUI off Apple's platforms), by
        // its release's tag: its own dependencies are by revision and branch,
        // so SwiftPM won't take it by version (tools/released_pins.sh allows
        // this one).
        .package(url: "https://github.com/AttilaTheFun/isomer.git", revision: "v0.50.1"),
        .package(
            url: "https://github.com/AttilaTheFun/agent_ui.git",
            exact: "0.51.0"
        ),
        // agent_protocol's gRPC (agent_protocol/, VisorDriver, the native
        // runner): the versions Isomer resolves already, and its protobuf.
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.12.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.5.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
        // SSH as a road to a server: the client's own SSH connection, a
        // port forwarded to the server on its loopback (SSHAgentServer).
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        // The Runner's GitHub proxy: its own certificate authority
        // (libraries/visor_runner, RunnerCA).
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.1"),
        // …and its TLS, for GitHub's hosts.
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.6"),
        // SQLite for the message cache: the system's on Apple's platforms,
        // its vendored amalgamation elsewhere (WebAssembly included).
        .package(
            url: "https://github.com/AttilaTheFun/swift_sql.git",
            exact: "0.35.0"
        ),
        // UpdateKit (ApplicationUpdates until it left the applications
        // repository, 7 Nov 2026): the build this app is, written at launch to
        // the database it shares with Applications (in the app group its
        // Info.plist names, tools/signing), and its updates told of.
        .package(
            url: "https://github.com/AttilaTheFun/update_kit.git",
            exact: "0.13.0"
        ),
    ]
)
