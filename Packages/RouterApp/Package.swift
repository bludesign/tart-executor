// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RouterApp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RouterApp", targets: [
            "RouterApp"
        ])
    ],
    dependencies: [
        .package(path: "../TartCommon"),
        .package(path: "../Logging"),
        .package(path: "../EnvironmentSettings"),
        .package(url: "https://github.com/swhitty/FlyingFox.git", .upToNextMajor(from: "0.21.0"))
    ],
    targets: [
        .target(name: "RouterApp", dependencies: [
            .product(name: "TartCommon", package: "TartCommon"),
            .product(name: "LoggingData", package: "Logging"),
            .product(name: "LoggingDomain", package: "Logging"),
            .product(name: "EnvironmentSettings", package: "EnvironmentSettings"),
            .product(name: "FlyingFox", package: "FlyingFox")
        ])
    ]
)
