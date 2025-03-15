// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "EnvironmentSettings",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EnvironmentSettings", targets: [
            "EnvironmentSettings"
        ])
    ],
    dependencies: [
        .package(path: "../VirtualMachine"),
        .package(path: "../GitHub"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3")
    ],
    targets: [
        .target(name: "EnvironmentSettings", dependencies: [
            .product(name: "VirtualMachineData", package: "VirtualMachine"),
            .product(name: "VirtualMachineDomain", package: "VirtualMachine"),
            .product(name: "GitHubDomain", package: "GitHub"),
            .product(name: "Yams", package: "Yams")
        ])
    ]
)
