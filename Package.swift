// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RotateWin",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "RotateWin",
            path: "Sources/RotateWin"
        )
    ]
)
