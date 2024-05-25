// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "FlySightCore",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "FlySightCore",
            targets: ["FlySightCore"]),
    ],
    dependencies: [
        // Specify any dependencies here
    ],
    targets: [
        .target(
            name: "FlySightCore",
            dependencies: []),
        .testTarget(
            name: "FlySightCoreTests",
            dependencies: ["FlySightCore"]),
    ]
)
