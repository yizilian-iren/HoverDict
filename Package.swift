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
        ),
        // Swift Testing (not XCTest): Command Line Tools ship Testing.framework only.
        // Run with `make test`.
        .testTarget(
            name: "HoverDictTests",
            dependencies: ["HoverDict"],
            path: "Tests/HoverDictTests",
            // With CLT alone SwiftPM only sometimes passes the Testing macro plugin dir,
            // and the build then fails with "plugin for module 'TestingMacros' not found".
            // Naming it explicitly makes `swift test` reliable; harmless under full Xcode.
            swiftSettings: [
                .unsafeFlags(["-plugin-path",
                              "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])
            ]
        )
    ]
)
