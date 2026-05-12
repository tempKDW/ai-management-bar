// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeMenubar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClaudeMenubar", targets: ["ClaudeMenubar"]),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeMenubar",
            path: "Sources/ClaudeMenubar"
        ),
    ]
)
