// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "OpenTraffic",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenTrafficCore", targets: ["OpenTrafficCore"]),
        .executable(name: "OpenTraffic", targets: ["OpenTraffic"]),
        .executable(name: "opentraffic-mcp", targets: ["opentraffic-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(
            name: "OpenTrafficCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
        .executableTarget(
            name: "OpenTraffic",
            dependencies: ["OpenTrafficCore"],
            exclude: ["Resources"]
        ),
        // The stdio MCP bridge bundled in the app; Foundation only, so it stays small.
        .executableTarget(name: "opentraffic-mcp"),
        .testTarget(
            name: "OpenTrafficCoreTests",
            dependencies: [
                "OpenTrafficCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ]
        ),
    ]
)
