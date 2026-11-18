// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LokalhostManager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LokalhostManager"),
        .testTarget(name: "LokalhostManagerTests", dependencies: ["LokalhostManager"])
    ]
)
