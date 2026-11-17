// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FloatChat",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FloatChat",
            path: "Sources/FloatChat"
        ),
    ]
)
