// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnipScrollCaptureCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SnipScrollCaptureCore", targets: ["SnipScrollCaptureCore"])
    ],
    targets: [
        .target(
            name: "SnipScrollCaptureCore",
            path: "Snip",
            exclude: ["App/main.swift", "Resources"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "SnipCaptureUITests",
            dependencies: ["SnipScrollCaptureCore"],
            path: "Tests/SnipCaptureUITests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SnipScrollCaptureCoreTests",
            dependencies: ["SnipScrollCaptureCore"],
            path: "Tests/SnipScrollCaptureCoreTests"
        )
    ]
)
