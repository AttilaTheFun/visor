// swift-tools-version: 5.9

// The SwiftPM dependencies Visor consumes through rules_swift_package_manager:
// AgentUI (the agent chat page and the navigation containers; a private
// repo — git's credential helper from `gh auth setup-git` lets Bazel's clone
// and SwiftPM's resolve reach it). rspm reads Package.resolved for the pinned
// graph and generates one `@swiftpkg_<name>` repo per package.
import PackageDescription

let package = Package(
    name: "visor_swift_packages",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [
        // SwiftTerm 1.11+ generates its build info with an SPM plugin, which
        // rules_swift_package_manager does not run; 1.10.1 is the last without.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.10.1"),
        .package(
            url: "https://github.com/AttilaTheFun/agent_ui.git",
            revision: "f98ee55859a93be15b6734b4f17d47071102172a"
        ),
        // The transcript cache: indexed, searchable rows of every session's
        // file, kept by the server off the main thread.
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", exact: "0.15.3"),
    ]
)
