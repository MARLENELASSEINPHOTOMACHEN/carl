// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "carl",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "carl",
            path: "Sources"
        )
    ]
)
