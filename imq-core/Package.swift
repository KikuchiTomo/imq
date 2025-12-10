// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "imq-core",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "IMQCore",
            targets: ["IMQCore"]
        ),
        .executable(
            name: "imq",
            targets: ["IMQCLI"]
        ),
        .executable(
            name: "imq-server",
            targets: ["IMQServer"]
        )
    ],
    dependencies: [
        // Vapor - Web framework for REST API and WebSocket
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),

        // ArgumentParser - CLI argument parsing
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),

        // SQLite.swift - SQLite ORM
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.0"),

        // AsyncHTTPClient - HTTP client
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.19.0"),

        // Swift Log - Logging
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),

        // Swift Crypto - HMAC for webhook signatures
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        // IMQCore - Main library
        .target(
            name: "IMQCore",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            path: "Sources/IMQCore",
            resources: [
                .copy("../../Resources")
            ]
        ),

        // IMQCLI - Command-line interface
        .executableTarget(
            name: "IMQCLI",
            dependencies: [
                "IMQCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/IMQCLI"
        ),

        // IMQServer - REST API server
        .executableTarget(
            name: "IMQServer",
            dependencies: [
                "IMQCore"
            ],
            path: "Sources/IMQServer"
        ),

        // Tests
        .testTarget(
            name: "IMQCoreTests",
            dependencies: ["IMQCore"],
            path: "Tests/IMQCoreTests"
        )
    ]
)
