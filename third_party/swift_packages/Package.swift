// swift-tools-version: 5.9

// The SwiftPM dependencies Visor consumes through rules_swift_package_manager:
// AgentUI (the agent chat page and the navigation containers), swift-nio-ssh,
// swift_sql (SQLite for the message cache, on every host), and oss's client. rspm reads
// Package.resolved for the pinned graph and generates one `@swiftpkg_<name>`
// repo per package.
import PackageDescription

let package = Package(
    name: "visor_swift_packages",
    platforms: [.iOS("18.0"), .macOS("15.0")],
    dependencies: [
        .package(
            url: "https://github.com/AttilaTheFun/agent_ui.git",
            exact: "0.38.0"
        ),
        // SSH as a road to a server: the client's own SSH connection, a
        // port forwarded to the server on its loopback (SSHAgentServer).
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        // SQLite for the message cache: the system's on Apple's platforms,
        // its vendored amalgamation elsewhere (WebAssembly included).
        .package(
            url: "https://github.com/AttilaTheFun/swift_sql.git",
            exact: "0.35.0"
        ),
        // oss's client (OSSClient): the server runs sessions' agents in
        // containers on an oss server.
        .package(
            url: "https://github.com/AttilaTheFun/oss.git",
            exact: "0.1.0"
        ),
    ]
)
