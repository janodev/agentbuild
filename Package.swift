// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "agentbuild",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "agentbuild", targets: ["AgentBuildCLI"]),
        .library(name: "AgentBuildCore", targets: ["AgentBuildCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.0"),
    ],
    targets: [
        .target(
            name: "AgentBuildCore",
            dependencies: [.product(name: "Subprocess", package: "swift-subprocess")]
        ),
        .executableTarget(
            name: "AgentBuildCLI",
            dependencies: [
                "AgentBuildCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "AgentBuildCoreTests", dependencies: ["AgentBuildCore"]),
    ],
    swiftLanguageModes: [.v6]
)
