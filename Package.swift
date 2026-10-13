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
    dependencies: [],
    targets: [
        .target(
            name: "KansoCore",
            dependencies: [],
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
