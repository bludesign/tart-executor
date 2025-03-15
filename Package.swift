// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Tart",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "tart-router", targets: ["TartRouter"]),
        .executable(name: "tart-executor", targets: ["TartExecutor"])
    ],
    dependencies: [
        .package(path: "Packages/EnvironmentSettings"),
        .package(path: "Packages/RouterApp"),
        .package(path: "Packages/ExecutorApp"),
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.0.0")
    ],
    targets: [
        .executableTarget(
            name: "TartRouter",
            dependencies: [
                .product(name: "EnvironmentSettings", package: "EnvironmentSettings"),
                .product(name: "RouterApp", package: "RouterApp")
            ],
            path: "tart-router",
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
        ),
        
        .executableTarget(
            name: "TartExecutor",
            dependencies: [
                .product(name: "EnvironmentSettings", package: "EnvironmentSettings"),
                .product(name: "ExecutorApp", package: "ExecutorApp")
            ],
            path: "tart-executor",
            plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
        )
    ]
)
