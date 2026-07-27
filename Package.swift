// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MiniSlack",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MiniSlack", targets: ["MiniSlack"])
    ],
    dependencies: [
        .package(url: "https://github.com/divadretlaw/EmojiText", from: "4.4.0")
    ],
    targets: [
        .executableTarget(
            name: "MiniSlack",
            dependencies: [
                .product(name: "EmojiText", package: "EmojiText")
            ],
            path: "Sources/MiniSlack"
        ),
        .testTarget(
            name: "MiniSlackTests",
            dependencies: ["MiniSlack"],
            path: "Tests/MiniSlackTests"
        ),
    ]
)
