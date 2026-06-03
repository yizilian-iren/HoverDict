// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HoverDict",
    // Setting the platform floor to macOS 14 makes the whole target min-deployment 14.0,
    // so ScreenCaptureKit's macOS 14 APIs (SCScreenshotManager) are available without
    // per-call @available annotations.
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "HoverDict",
            path: "Sources/HoverDict"
        )
    ]
)
