// swift-tools-version: 6.2
import PackageDescription

// ALL targets compile in Swift 5 language mode on purpose: Swift 6 mode
// injects _checkExpectedExecutor runtime checks into every @objc method
// on @MainActor classes, and those checks segfault in the broken
// concurrency runtime on macOS 27.0 beta (26A5406e). Swift 5 mode compiles
// the same @MainActor/@Observable code without injecting any runtime
// executor checks — isolation is still checked at compile time (warnings,
// not errors). This is the single change that eliminates every crash
// vector at once. When the macOS beta is fixed (27.2+), switch back to
// Swift 6 mode by removing the swiftSettings below.
let package = Package(
    name: "Motionpaper",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "MotionpaperKit",
            path: "Sources/MotionpaperKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Motionpaper",
            dependencies: ["MotionpaperKit"],
            path: "Sources/Motionpaper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MotionpaperLockHelper",
            dependencies: ["MotionpaperKit"],
            path: "Sources/MotionpaperLockHelper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MotionpaperKitTests",
            dependencies: ["MotionpaperKit"],
            path: "Tests/MotionpaperKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
