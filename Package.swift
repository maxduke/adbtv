// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ADBTV",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ADBClientCore",
            targets: ["ADBClientCore"]
        )
    ],
    targets: [
        .target(
            name: "ADBClientCore"
        ),
        .testTarget(
            name: "ADBClientCoreTests",
            dependencies: ["ADBClientCore"]
        )
    ]
)
