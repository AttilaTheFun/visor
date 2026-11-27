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
        // 0.6.0's wrapper takes its token on a descriptor (AGENT_TOKEN_FD,
        // the Sessions container's standard input) or in a file it deletes,
        // and makes itself undumpable on Linux (agent_protocol#17), on
        // 0.5.0's conversation hand-back (DriverMessage.hand_back,
        // ReturnConversation, WrapperHello.protocol 2; #15) and
        // RenewResponse.token (#14), and 0.4.0's Job.token, MCP, approvals
        // and Job.skip_permissions (#9 to #13).
        .package(
            url: "https://github.com/AttilaTheFun/agent_protocol.git",
            exact: "0.6.0"
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
        // Shireworks Kit (shake_kit and update_kit in one package, Logan, 24
        // Nov 2026): what an app developed through Shireworks builds in. Its
        // crashes filed as GitHub issues (ShireworksCrashes, on KSCrash), a
        // shake or Help › Report a Bug… filing one (ShireworksShake), and its
        // build written to the database it shares with Shireworks, whose
        // offers of an update it answers (ShireworksUpdates). Visor's Apple
        // apps alone (applications/visor_ios, visor_mac, visor_disk_utility),
        // at their root views and scenes: nothing portable (visor_ui,
        // visor_client) depends on it. Each capability does nothing without
        // the Info.plist keys and entitlements CI's builds to publish carry
        // (tools/signing, tools/shared_sign_in). Exactly 0.2.1: the public
        // repository's crash privacy (from 0.1.0; Visor's is public), and
        // Report a Bug's sheet opening at once.
        .package(
            url: "https://github.com/AttilaTheFun/shireworks_kit.git",
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
        // build_tools (AttilaTheFun/build_tools): its `sign`, which CI's
        // signing job (tools/ci/sign_builds.sh, //tools/ci:sign) signs the
        // Apple apps with, stamping the build settings they were built
        // without (`sign apple --add-infoplist`, `--add-groups`: 0.7.0,
        // build_tools#18 and #20; 0.8.0 fills `$(AppIdentifierPrefix)` in them from
        // each app's profile, build_tools#22). It brings swift-subprocess.
        .package(url: "https://github.com/AttilaTheFun/build_tools.git", exact: "0.8.0"),
    ]
)
