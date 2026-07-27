// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MiniSlack",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MiniSlack", targets: ["MiniSlack"])
    ],
    targets: [
        .executableTarget(
            name: "MiniSlack",
            path: "Sources/MiniSlack"
        ),
        .testTarget(
            name: "MiniSlackTests",
            dependencies: ["MiniSlack"],
            path: "Tests/MiniSlackTests"
        ),
    ]
)
