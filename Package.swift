// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "agentbuild",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "agentbuild", targets: ["AgentBuildCLI"]),
        .library(name: "AgentBuildCore", targets: ["AgentBuildCore"]),
        .library(name: "NotikaAdapter", targets: ["NotikaAdapter"]),
        .library(name: "ABDiffAdapter", targets: ["ABDiffAdapter"]),
        .library(name: "GunshipAdapter", targets: ["GunshipAdapter"]),
    ],
    dependencies: [
        .package(url: "git@github.com:janodev/agentlease.git", revision: "db00b7f2b7b307397850ca25d41f33437a7d3d24"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.0"),
    ],
    targets: [
        .target(
            name: "AgentBuildCLISupport",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .target(
            name: "NotikaAdapter",
            dependencies: [
                "AgentBuildCore", "AgentBuildCLISupport",
                .product(name: "AgentLeaseCore", package: "agentlease"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Adapters/Notika/Sources"
        ),
        .target(
            name: "ABDiffAdapter",
            dependencies: [
                "AgentBuildCore", "AgentBuildCLISupport",
                .product(name: "AgentLeaseCore", package: "agentlease"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Adapters/ABDiff/Sources"
        ),
        .target(
            name: "GunshipAdapter",
            dependencies: [
                "AgentBuildCore", "AgentBuildCLISupport",
                .product(name: "AgentLeaseCore", package: "agentlease"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Adapters/Gunship/Sources"
        ),
        .target(
            name: "AgentBuildTestSupport",
            dependencies: ["AgentBuildCore", .product(name: "AgentLeaseCore", package: "agentlease")],
            path: "Tests/Support"
        ),
        .target(
            name: "AgentBuildCore",
            dependencies: [
                .product(name: "AgentLeaseCore", package: "agentlease"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ]
        ),
        .executableTarget(
            name: "AgentBuildCLI",
            dependencies: [
                "AgentBuildCore",
                "AgentBuildCLISupport", "NotikaAdapter", "ABDiffAdapter", "GunshipAdapter",
                .product(name: "AgentLeaseCore", package: "agentlease"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "AgentBuildCoreTests",
            dependencies: ["AgentBuildCore", "AgentBuildTestSupport", .product(name: "AgentLeaseCore", package: "agentlease")]
        ),
        .testTarget(
            name: "NotikaAdapterTests",
            dependencies: ["NotikaAdapter", "AgentBuildCore", "AgentBuildTestSupport", .product(name: "AgentLeaseCore", package: "agentlease")],
            path: "Adapters/Notika/Tests"
        ),
        .testTarget(
            name: "ABDiffAdapterTests",
            dependencies: ["ABDiffAdapter", "AgentBuildCore", "AgentBuildTestSupport", .product(name: "AgentLeaseCore", package: "agentlease")],
            path: "Adapters/ABDiff/Tests"
        ),
        .testTarget(
            name: "GunshipAdapterTests",
            dependencies: ["GunshipAdapter", "AgentBuildCore", "AgentBuildTestSupport", .product(name: "AgentLeaseCore", package: "agentlease")],
            path: "Adapters/Gunship/Tests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
