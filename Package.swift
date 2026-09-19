// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LuckySQL",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LuckySQL", targets: ["LuckySQL"])],
    dependencies: [
        .package(url: "https://github.com/vapor/mysql-nio.git", exact: "1.8.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0")
    ],
    targets: [
        .executableTarget(
            name: "LuckySQL",
            dependencies: [
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .testTarget(name: "LuckySQLTests", dependencies: ["LuckySQL"])
    ]
)
