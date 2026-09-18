// swift-tools-version: 5.9
import PackageDescription

// Plain on purpose: this package has to build on a Mac with only the Command Line Tools,
// so no manifest API beyond what tools-version 5.9 ships, and no external dependencies.
let package = Package(
    name: "Docent",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "DocentKit",
            path: "Sources/DocentKit"
        ),
        .executableTarget(
            name: "docent",
            dependencies: ["DocentKit"],
            path: "Sources/DocentCLI"
        ),
        .executableTarget(
            name: "DocentApp",
            dependencies: ["DocentKit"],
            path: "Sources/DocentApp",
            exclude: ["Support/Info.plist"]
        ),
        .testTarget(
            name: "DocentKitTests",
            dependencies: ["DocentKit"],
            path: "Tests/DocentKitTests"
        ),
    ]
)
