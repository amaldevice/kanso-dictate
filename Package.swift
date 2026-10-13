// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KansoDictate",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "KansoCore", targets: ["KansoCore"]),
        .executable(name: "KansoDictate", targets: ["KansoDictate"]),
        .executable(name: "KansoCoreTests", targets: ["KansoCoreTests"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1")
    ],
    targets: [
        .target(
            name: "KansoCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "KansoDictate",
            dependencies: ["KansoCore"],
            exclude: ["Resources"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "KansoCoreTests",
            dependencies: ["KansoCore"],
            path: "Tests/KansoCoreTests",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ]
)
