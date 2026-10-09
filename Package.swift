// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Motionpaper",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "MotionpaperKit",
            path: "Sources/MotionpaperKit"
        ),
        .executableTarget(
            name: "Motionpaper",
            dependencies: ["MotionpaperKit"],
            path: "Sources/Motionpaper"
        ),
        .executableTarget(
            name: "MotionpaperLockHelper",
            dependencies: ["MotionpaperKit"],
            path: "Sources/MotionpaperLockHelper"
        ),
        .testTarget(
            name: "MotionpaperKitTests",
            dependencies: ["MotionpaperKit"],
            path: "Tests/MotionpaperKitTests"
        )
    ]
)
