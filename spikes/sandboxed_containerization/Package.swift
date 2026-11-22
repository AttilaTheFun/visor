// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VisorSandboxSpike",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", exact: "0.57.0"),
    ],
    targets: [
        .executableTarget(
            name: "VisorSandboxSpike",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
            ]
        ),
    ]
)
