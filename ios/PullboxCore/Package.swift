// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PullboxCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PullboxCore", targets: ["PullboxCore"])],
    targets: [
        .target(name: "PullboxCore"),
        .testTarget(name: "PullboxCoreTests", dependencies: ["PullboxCore"])
    ]
)
