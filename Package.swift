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
        ),
        .library(
            name: "ADBTVApp",
            targets: ["ADBTVApp"]
        )
    ],
    targets: [
        .target(
            name: "ADBClientCore"
        ),
        .target(
            name: "ADBTVApp",
            dependencies: ["ADBClientCore"]
        ),
        .testTarget(
            name: "ADBClientCoreTests",
            dependencies: ["ADBClientCore"]
        ),
        .testTarget(
            name: "ADBTVAppTests",
            dependencies: ["ADBTVApp"]
        )
    ]
)
