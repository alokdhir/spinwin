// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpinWin",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "SpinWin",
            path: "Sources/SpinWin"
        )
    ]
)
