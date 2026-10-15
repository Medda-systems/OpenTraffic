// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "OpenTraffic",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenTrafficCore", targets: ["OpenTrafficCore"]),
        .executable(name: "OpenTraffic", targets: ["OpenTraffic"]),
        .executable(name: "opentraffic-mcp", targets: ["opentraffic-mcp"]),
        .executable(name: "opentraffic-cli", targets: ["opentraffic-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        // Automatic updates.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // The private socket between the app and its own tools; Foundation only.
        .target(name: "OpenTrafficSocket"),
        .target(
            name: "OpenTrafficCore",
            dependencies: [
                "OpenTrafficSocket",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "OpenTraffic",
            dependencies: [
                "OpenTrafficCore",
                "OpenTrafficSocket",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            exclude: ["Resources"]
        ),
        // The stdio MCP bridge bundled in the app; Foundation only, so it stays small.
        .executableTarget(name: "opentraffic-mcp", dependencies: ["OpenTrafficSocket"]),
        // The `opentraffic` command, a client of the local API bundled in the app; Foundation only too.
        .executableTarget(name: "opentraffic-cli", dependencies: ["OpenTrafficSocket"]),
        .testTarget(name: "OpenTrafficCLITests", dependencies: ["opentraffic-cli"]),
        .testTarget(
            name: "OpenTrafficCoreTests",
            dependencies: [
                "OpenTrafficCore",
                "OpenTrafficSocket",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
    ]
)
