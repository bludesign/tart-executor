// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ExecutorApp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ExecutorApp", targets: [
            "ExecutorApp"
        ])
    ],
    dependencies: [
        .package(path: "../TartCommon"),
        .package(path: "../VirtualMachine"),
        .package(path: "../Logging"),
        .package(path: "../EnvironmentSettings"),
        .package(path: "../FileSystem"),
        .package(path: "../GitHub"),
        .package(path: "../Networking"),
        .package(path: "../Shell"),
        .package(path: "../SSH"),
        .package(url: "https://github.com/swhitty/FlyingFox.git", .upToNextMajor(from: "0.21.0"))
    ],
    targets: [
        .target(name: "ExecutorApp", dependencies: [
            .product(name: "TartCommon", package: "TartCommon"),
            .product(name: "VirtualMachineData", package: "VirtualMachine"),
            .product(name: "VirtualMachineDomain", package: "VirtualMachine"),
            .product(name: "LoggingData", package: "Logging"),
            .product(name: "LoggingDomain", package: "Logging"),
            .product(name: "EnvironmentSettings", package: "EnvironmentSettings"),
            .product(name: "FileSystemData", package: "FileSystem"),
            .product(name: "GitHubData", package: "GitHub"),
            .product(name: "GitHubDomain", package: "GitHub"),
            .product(name: "NetworkingData", package: "Networking"),
            .product(name: "ShellData", package: "Shell"),
            .product(name: "SSHData", package: "SSH"),
            .product(name: "FlyingFox", package: "FlyingFox")
        ])
    ]
)
