// swift-tools-version: 5.9

// The SwiftPM dependencies Visor consumes through rules_swift_package_manager:
// AgentUI (the agent chat page, the navigation containers and the terminal,
// which brings SwiftTerm's emulator from github.com/AttilaTheFun/SwiftTerm; a private
// repo — git's credential helper from `gh auth setup-git` lets Bazel's clone
// and SwiftPM's resolve reach it). rspm reads Package.resolved for the pinned
// graph and generates one `@swiftpkg_<name>` repo per package.
import PackageDescription

let package = Package(
    name: "visor_swift_packages",
    platforms: [.iOS("18.0"), .macOS("15.0")],
    dependencies: [
        .package(
            url: "https://github.com/AttilaTheFun/agent_ui.git",
            revision: "a64620ace49b462565ed2f0b3b18ca53aea7527f"
        ),
        // The transcript cache: indexed, searchable rows of every session's
        // file, kept by the server off the main thread.
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", exact: "0.15.3"),
    ]
)
