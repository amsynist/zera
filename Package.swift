// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zera",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "Packages/AndropKit"),
        // Murmur: on-device Whisper speech model for dictation (Core ML, Neural Engine).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1")
    ],
    targets: [
        .executableTarget(
            name: "Zera",
            dependencies: [.product(name: "WhisperKit", package: "WhisperKit"), .product(name: "AndropKit", package: "AndropKit")],
            path: "Sources/Zera", exclude: ["Androp/AGENTS.md"]
        ),
        // `swift test` — parser, CLI capability detection, prompts, argv building, Markdown.
        .testTarget(
            name: "ZeraTests",
            dependencies: ["Zera"],
            path: "Tests/ZeraTests"
        )
    ]
)
