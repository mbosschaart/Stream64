// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Stream64",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20"),
    ],
    targets: [
        .executableTarget(
            name: "Stream64",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/Stream64",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "Stream64Tests",
            dependencies: [
                "Stream64",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
    ]
)
