// swift-tools-version: 5.9

// The SwiftPM dependencies Visor consumes through rules_swift_package_manager:
// AgentUI (the agent chat page and the navigation containers). rspm reads
// Package.resolved for the pinned graph and generates one `@swiftpkg_<name>`
// repo per package.
import PackageDescription

let package = Package(
    name: "visor_swift_packages",
    platforms: [.iOS("18.0"), .macOS("15.0")],
    dependencies: [
        .package(
            url: "https://github.com/AttilaTheFun/agent_ui.git",
            revision: "9cf34abbf76168221d97a89e8dc2e200cf05e676"
        ),
        // SSH as a road to a server: the client's own SSH connection, a
        // port forwarded to the server on its loopback (SSHAgentServer).
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
    ]
)
