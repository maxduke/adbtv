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
    dependencies: [
        .package(
            url: "https://github.com/firebase/boringSSL-SwiftPM.git",
            exact: "0.41.0"
        )
    ],
    targets: [
        .target(
            name: "CADBPairingCrypto",
            dependencies: [
                .product(name: "openssl_grpc", package: "boringSSL-SwiftPM")
            ]
        ),
        .target(
            name: "ADBClientCore",
            dependencies: ["CADBPairingCrypto"]
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
