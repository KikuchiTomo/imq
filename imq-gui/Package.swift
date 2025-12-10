// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "imq-gui",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "imq-gui",
            targets: ["Run"]
        )
    ],
    dependencies: [
        // Vapor - Web framework
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),

        // Leaf - Template engine
        .package(url: "https://github.com/vapor/leaf.git", from: "4.3.0"),

        // Swift Log - Logging
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
    ],
    targets: [
        // IMQGUILib - Main library
        .target(
            name: "IMQGUILib",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Leaf", package: "leaf"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/IMQGUILib",
            resources: [
                .copy("../../Resources")
            ]
        ),

        // Run - Executable
        .executableTarget(
            name: "Run",
            dependencies: [
                "IMQGUILib"
            ],
            path: "Sources/Run"
        ),

        // Tests
        .testTarget(
            name: "IMQGUITests",
            dependencies: ["IMQGUILib"],
            path: "Tests/IMQGUITests"
        )
    ]
)
