// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacCleaner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacCleaner", targets: ["MacCleaner"]),
        .executable(name: "mac-cleaner", targets: ["CLI"]),
        .library(name: "CleanerCore", targets: ["CleanerCore"]),
    ],
    targets: [
        .target(name: "CleanerCore", path: "Sources/CleanerCore"),
        .executableTarget(name: "MacCleaner", dependencies: ["CleanerCore"], path: "Sources/MacCleaner"),
        .executableTarget(name: "CLI", dependencies: ["CleanerCore"], path: "Sources/CLI"),
        .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"], path: "Tests/CleanerCoreTests"),
        .testTarget(name: "CLITests", dependencies: ["CLI", "CleanerCore"], path: "Tests/CLITests"),
    ]
)
