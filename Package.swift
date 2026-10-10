// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Snag",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Snag", path: "Sources/App")
    ]
)
