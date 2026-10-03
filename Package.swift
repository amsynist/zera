// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Zera",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Zera",
            path: "Sources/Zera"
        ),
        // `swift test` — parser, CLI capability detection, prompts, argv building, Markdown.
        .testTarget(
            name: "ZeraTests",
            dependencies: ["Zera"],
            path: "Tests/ZeraTests"
        )
    ]
)
