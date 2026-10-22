// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "iSim-mcp",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "isim-mcp", targets: ["isim-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "isim-mcp",
            dependencies: [
                "ISimMCP",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "ISimMCP",
            dependencies: [
                "DeviceCore",
                "SimctlBackend",
                "DevicectlBackend",
                "ProcessKit",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(name: "DeviceCore", dependencies: ["ProcessKit"]),
        .target(name: "SimctlBackend", dependencies: ["DeviceCore", "ProcessKit"]),
        .target(name: "DevicectlBackend", dependencies: ["DeviceCore", "ProcessKit"]),
        .target(name: "ProcessKit"),

        .target(name: "TestSupport", dependencies: ["ProcessKit"], path: "Tests/TestSupport"),
        .testTarget(name: "ProcessKitTests", dependencies: ["ProcessKit"]),
        .testTarget(name: "DeviceCoreTests", dependencies: ["DeviceCore", "TestSupport"]),
        .testTarget(
            name: "BackendTests",
            dependencies: ["SimctlBackend", "DevicectlBackend", "DeviceCore", "ProcessKit", "TestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ISimMCPTests",
            dependencies: ["ISimMCP", "DeviceCore", "SimctlBackend", "ProcessKit", "TestSupport", .product(name: "MCP", package: "swift-sdk")]
        ),
    ]
)
