// swift-tools-version:6.0
// agent_protocol: what Visor and Shireworks share, and the one program both
// run their agents under. Three gRPC services (protos/agent_protocol/v1):
// AgentDispatcher (the queue runners pull jobs from), AgentDriver (where an
// agent is watched and steered) and AgentWrapper (the wrapper, for the
// runner that started it); and agent-wrapper, which runs Claude, Codex and
// the others behind one interface. The protos' Swift is generated
// (tools/generate.sh) and kept in Sources/AgentProtocol.

import PackageDescription

/// Swift 6, and a warning is an error.
let strict: [SwiftSetting] = [.swiftLanguageMode(.v6), .unsafeFlags(["-warnings-as-errors"])]

let package = Package(
    name: "agent_protocol",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AgentProtocol", targets: ["AgentProtocol"]),
        .executable(name: "agent-wrapper", targets: ["AgentWrapperMain"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.39.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.5.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.12.0"),
    ],
    targets: [
        // The protos' messages and their services' clients and servers.
        .target(name: "AgentProtocol",
                dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf"),
                               .product(name: "GRPCCore", package: "grpc-swift-2"),
                               .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf")],
                swiftSettings: [.swiftLanguageMode(.v6)]),
        // The wrapper: harnesses, the driver link, its own service.
        .target(name: "AgentWrapper",
                dependencies: ["AgentProtocol",
                               .product(name: "GRPCCore", package: "grpc-swift-2"),
                               .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport")],
                swiftSettings: strict),
        .executableTarget(name: "AgentWrapperMain", dependencies: ["AgentWrapper"], swiftSettings: strict),
        .testTarget(name: "AgentWrapperTests", dependencies: ["AgentWrapper", "AgentProtocol"], swiftSettings: strict),
    ]
)
