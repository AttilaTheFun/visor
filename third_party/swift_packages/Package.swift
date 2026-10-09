// swift-tools-version: 5.9

// The SwiftPM dependencies Visor consumes through rules_swift_package_manager:
// AgentUI (the agent chat page, the navigation containers and the terminal,
// which brings SwiftTerm's emulator from github.com/migueldeicaza/SwiftTerm;
// swiftterm.patch adds what its build plugin generates, since rspm runs no
// SwiftPM plugins). rspm reads Package.resolved for the pinned graph and
// generates one `@swiftpkg_<name>` repo per package.
import PackageDescription

let package = Package(
    name: "visor_swift_packages",
    platforms: [.iOS("18.0"), .macOS("15.0")],
    dependencies: [
        .package(
            url: "https://github.com/AttilaTheFun/agent_ui.git",
            revision: "8ea5e0b375c65317dc0fd52a073ab843c532e6da"
        ),
        // The transcript cache: indexed, searchable rows of every session's
        // file, kept by the server off the main thread.
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", exact: "0.15.3"),
        // SSH as a road to a server: the client's own SSH connection, a
        // port forwarded to the server on its loopback (SSHAgentServer).
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
    ]
)
