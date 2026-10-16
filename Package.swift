// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lopper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Lopper", targets: ["Lopper"]),
        .library(name: "LopperCLI", targets: ["LopperCLI"]),
        .executable(name: "lopper-scan", targets: ["LopperScan"]),
        .executable(name: "lop", targets: ["lop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(name: "Lopper"),
        .target(
            name: "LopperCLI",
            dependencies: [
                "Lopper",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]),
        .executableTarget(name: "lop", dependencies: ["LopperCLI"]),
        .executableTarget(name: "LopperScan", dependencies: ["Lopper"]),
        .testTarget(name: "LopperTests", dependencies: ["Lopper"]),
        .testTarget(name: "LopperCLITests", dependencies: ["LopperCLI", "Lopper"]),
    ]
)
