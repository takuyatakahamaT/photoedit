// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PhotoBench",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PhotoCore", targets: ["PhotoCore"]),
        .library(name: "PhotoBenchAppSupport", targets: ["PhotoBenchAppSupport"]),
        .library(
            name: "PhotoBenchCalibrationSupport",
            targets: ["PhotoBenchCalibrationSupport"]
        ),
        .executable(name: "PhotoBench", targets: ["PhotoBenchApp"]),
        .executable(name: "PhotoBenchCalibration", targets: ["PhotoBenchCalibration"]),
        .executable(name: "PhotoBenchBenchmark", targets: ["PhotoBenchBenchmark"])
    ],
    targets: [
        .target(
            name: "PhotoCore",
            path: "Sources/PhotoCore"
        ),
        .target(
            name: "PhotoBenchAppSupport",
            path: "Sources/PhotoBenchAppSupport"
        ),
        .executableTarget(
            name: "PhotoBenchApp",
            dependencies: ["PhotoCore", "PhotoBenchAppSupport"],
            path: "Sources/PhotoBenchApp"
        ),
        .executableTarget(
            name: "PhotoBenchCalibration",
            dependencies: ["PhotoCore", "PhotoBenchCalibrationSupport"],
            path: "Sources/PhotoBenchCalibration"
        ),
        .target(
            name: "PhotoBenchCalibrationSupport",
            dependencies: ["PhotoCore"],
            path: "Sources/PhotoBenchCalibrationSupport"
        ),
        .executableTarget(
            name: "PhotoBenchBenchmark",
            dependencies: ["PhotoCore", "PhotoBenchCalibrationSupport"],
            path: "Sources/PhotoBenchBenchmark"
        ),
        .testTarget(
            name: "PhotoCoreTests",
            dependencies: ["PhotoCore"],
            path: "Tests/PhotoCoreTests"
        ),
        .testTarget(
            name: "PhotoBenchAppSupportTests",
            dependencies: ["PhotoBenchAppSupport"],
            path: "Tests/PhotoBenchAppSupportTests"
        ),
        .testTarget(
            name: "PhotoBenchCalibrationSupportTests",
            dependencies: ["PhotoBenchCalibrationSupport", "PhotoCore"],
            path: "Tests/PhotoBenchCalibrationSupportTests"
        )
    ]
)
