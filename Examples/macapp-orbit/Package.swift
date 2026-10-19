// swift-tools-version: 6.0
import PackageDescription

// Orbit Orders: an ordinary SwiftUI app used as the fixture for sharing native Mac apps.
let package = Package(
    name: "Orbit",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Orbit", path: "Sources/Orbit"),
    ]
)
