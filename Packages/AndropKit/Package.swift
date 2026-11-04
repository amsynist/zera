// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "AndropKit", platforms: [.macOS(.v13)],
    products: [.library(name: "AndropKit", targets: ["AndropKit"])],
    targets: [.target(name: "AndropKit"), .testTarget(name: "AndropKitTests", dependencies: ["AndropKit"])])
