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
            revision: "3c74af906e76199d27cd5da0221d01a6b4c737eb"
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
        // oss's client (OSSClient): the machines sessions lease through
        // the server, and what each is using (oss main's commit, #8, until
        // 0.5.0 is published).
        .package(
            url: "https://github.com/AttilaTheFun/oss.git",
            revision: "2538f07811d8508d4037d1429d4c87ed42e2a8bd"
        ),
    ]
)
