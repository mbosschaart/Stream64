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
            exclude: ["UltimateViewer.code-workspace"],
            resources: [
                // Keep these at the bundle root. The Metal source is read at
                // runtime; its companion library is rebuilt explicitly by
                // Scripts/build-visualisation-palette.sh, not by SwiftPM.
                .copy("Resources/SIDVisualizationPalette.metal"),
                .copy("Resources/SIDVisualizationPalette.metallib"),
                .process("Resources/Stream64logo.png"),
                .process("Resources/ThirdPartyLicenses"),
                .process("Resources/c64cu-logo.webp"),
                .process("Resources/dirty-glass-mask.png"),
                .process("Resources/hvsc-7zz"),
                .process("Resources/kaos-1541.png"),
                .process("Resources/kaos-c64.png"),
                .process("Resources/kaos-cassette.png"),
                .process("Resources/kaos-floppy.png"),
                .process("Resources/kaos-joystick.png"),
                .process("Resources/kaos-monitor.png"),
                .process("Resources/kaos-smiley.png"),
                .process("Resources/logofactuur.png"),
                .process("Resources/showcase-1702.png"),
                .process("Resources/u64_logo_badgeman.jpg"),
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
