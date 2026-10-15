// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lopper",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Lopper", targets: ["Lopper"]),
        .executable(name: "lopper-scan", targets: ["LopperScan"]),
    ],
    targets: [
        .target(name: "Lopper"),
        .executableTarget(name: "LopperScan", dependencies: ["Lopper"]),
        .testTarget(name: "LopperTests", dependencies: ["Lopper"]),
    ]
)
