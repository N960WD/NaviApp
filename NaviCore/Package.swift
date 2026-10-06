// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NaviCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NaviCore", targets: ["NaviCore"]),
    ],
    targets: [
        .target(name: "NaviCore"),
        .testTarget(name: "NaviCoreTests", dependencies: ["NaviCore"]),
    ]
)
