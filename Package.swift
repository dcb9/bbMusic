// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "bbMusic",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "bbMusic", targets: ["bbMusic"])
    ],
    targets: [
        .executableTarget(
            name: "bbMusic",
            path: "Sources/bbMusic"
        ),
        .testTarget(
            name: "bbMusicTests",
            dependencies: ["bbMusic"],
            path: "Tests/bbMusicTests"
        )
    ]
)
