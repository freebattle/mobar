// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MoBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MoBar", path: "Sources/MoBar")
    ]
)
