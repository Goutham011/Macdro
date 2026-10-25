// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Macdro",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Macdro", targets: ["Macdro"]),
        .library(name: "MacdroKit", targets: ["MacdroKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "MacdroKit",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log")
            ],
            resources: [
                .copy("Resources/Web")
            ]
        ),
        .executableTarget(
            name: "Macdro",
            dependencies: ["MacdroKit"]
        ),
        .executableTarget(
            name: "MacdroSelfTest",
            dependencies: ["MacdroKit"]
        ),
        .executableTarget(
            name: "MacdroAudit",
            dependencies: ["MacdroKit"]
        ),
        .testTarget(
            name: "MacdroKitTests",
            dependencies: [
                "MacdroKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ]
        )
    ]
)
