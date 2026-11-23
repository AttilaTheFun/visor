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
        // Isomer's Swift (SwiftUI and the frameworks beneath it off Apple's
        // platforms; Foundation is in Isomer's Swift SDKs since 0.56), by
        // its release's tag: its own dependencies are by revision and branch,
        // so SwiftPM won't take it by version (tools/released_pins.sh allows
        // this one).
        .package(url: "https://github.com/AttilaTheFun/isomer.git", revision: "v0.58.1"),
        .package(
            url: "https://github.com/AttilaTheFun/agent_ui.git",
            exact: "0.51.0"
        ),
        // agent_protocol: its services' Swift (VisorDriver, the native
        // runner) and agent-wrapper (the Mac app's Helpers), by release:
        // 0.5.0 has the conversation hand-back (DriverMessage.hand_back,
        // ReturnConversation, WrapperHello.protocol 2; agent_protocol#15)
        // and RenewResponse.token (#14), on 0.4.0's Job.token, MCP,
        // approvals and Job.skip_permissions (#9 to #13).
        .package(
            url: "https://github.com/AttilaTheFun/agent_protocol.git",
            exact: "0.5.0"
        ),
        // Its gRPC: the versions Isomer resolves already, and its protobuf.
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.12.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.5.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
        // SSH as a road to a server: the client's own SSH connection, a
        // port forwarded to the server on its loopback (SSHAgentServer).
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.9.0"),
        // Certificates and TLS, at the versions gRPC's transport resolves.
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.1"),
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
        // Info.plist names, tools/signing). Applications alone tells of
        // updates (0.17). 0.18 adds UpdateKitInstall (a sandboxed app's
        // installer service) and the zip hand-over, neither of which Visor.app
        // asks for (no UpdateKitInstallsFromZip): it is handed the unpacked
        // build as before (VisorUpdates).
        .package(
            url: "https://github.com/AttilaTheFun/update_kit.git",
            exact: "0.18.0"
        ),
        // ShakeKit: a shake (Help › Report a Bug… on a Mac) files a GitHub
        // issue in this repository, with a screenshot and the app's logs.
        // The Apple apps alone (applications/visor_mac, visor_ios,
        // visor_macos), at their root view and scene: nothing portable
        // (visor_ui, visor_client) depends on it. Every build opts in
        // (`ShakeKitScope` in each Info.plist); its only sign-in, the one
        // Logan's apps share (Shireworks signed in on the same device), is
        // stamped into his CI builds alone (tools/shared_sign_in), so
        // anyone else's build reports nothing.
        .package(
            url: "https://github.com/AttilaTheFun/shake_kit.git",
            exact: "0.3.0"
        ),
        // Apple's Containerization (docs/containers.md): the Sessions
        // container's image store, ext4 unpacking and init filesystem, and,
        // from the container engine on, its VM. The Mac's alone
        // (libraries/visor_container, macOS only): nothing Linux builds
        // depends on it. Its vminit initfs is the same version's
        // (ContainerPins). It asks for swift-collections 1.2 or later, and
        // brings async-http-client and zstd.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.57.0"),
    ]
)
