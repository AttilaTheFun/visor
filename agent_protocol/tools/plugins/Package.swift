// swift-tools-version:6.0
// The protoc plugins tools/generate.sh runs, at the versions the package
// itself uses (keep them in step with ../../Package.swift).
import PackageDescription

let package = Package(
    name: "agent_protocol_plugins",
    dependencies: [
        // Exactly the oldest runtime a consumer builds with (Visor's Bazel build
        // resolves 1.39.0): code a plugin makes runs on its runtime or newer.
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.39.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.5.0"),
    ],
    // A package needs a target; the plugins are the dependencies' products.
    targets: [.target(name: "Placeholder", path: "Placeholder")]
)
