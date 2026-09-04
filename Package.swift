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
            path: "Snip/Managers",
            exclude: [
                "CaptureManager.swift",
                "FloatingImageManager.swift",
                "HotkeyManager.swift",
                "PreferencesManager.swift",
                "ScreenCaptureContentCache.swift",
                "ScrollCaptureManager.swift",
                "StatusBarManager.swift",
                "WindowDetectionManager.swift"
            ],
            sources: [
                "ScrollCaptureTranslationEstimator.swift",
                "ScrollCaptureStripComposer.swift",
                "ScrollCaptureLiveOffsetAccumulator.swift"
            ]
        ),
        .testTarget(
            name: "SnipScrollCaptureCoreTests",
            dependencies: ["SnipScrollCaptureCore"],
            path: "Tests/SnipScrollCaptureCoreTests"
        )
    ]
)
