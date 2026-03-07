// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Funz2.0",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // Vapor 4
        .package(url: "https://github.com/vapor/vapor.git", from: "4.110.0"),
        // Fluent ORM + PostgreSQL driver
        .package(url: "https://github.com/vapor/fluent.git", from: "4.12.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.10.0"),
        // Redis
        .package(url: "https://github.com/vapor/redis.git", from: "4.11.0"),
        // YAML config parsing
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        // JWT RS256
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.1.0"),
        // swift-log (Apple)
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        // Pinned to main: fix for Swift 6.2 MemberImportVisibility (unreleased > 1.21.0)
        .package(url: "https://github.com/vapor/async-kit.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Redis", package: "redis"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .product(name: "VaporTesting", package: "vapor"),
            ],
            path: "Tests"
        ),
    ]
)
