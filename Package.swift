// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Stream64",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Stream64",
            path: "Sources/Stream64"
        )
    ]
)
