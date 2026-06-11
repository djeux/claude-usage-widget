// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ClaudeUsageCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudeUsageCore", targets: ["ClaudeUsageCore"]),
    ],
    targets: [
        .target(name: "ClaudeUsageCore"),
        .testTarget(name: "ClaudeUsageCoreTests", dependencies: ["ClaudeUsageCore"]),
    ]
)
