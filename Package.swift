// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HeadphoneLimiter",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "HeadphoneLimiter", path: "Sources/HeadphoneLimiter")
    ]
)
