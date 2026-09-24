// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LuckySQL",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LuckySQL", targets: ["LuckySQL"])],
    dependencies: [
        .package(path: "Vendor/mysql-nio"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.34.1")
    ],
    targets: [
        .executableTarget(
            name: "LuckySQL",
            dependencies: [
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ]
        ),
        .testTarget(name: "LuckySQLTests", dependencies: ["LuckySQL"])
    ]
)
