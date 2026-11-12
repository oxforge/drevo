// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "fman",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "fman", targets: ["fman"]),
    ],
    targets: [
        .target(name: "FmanCore"),
        .target(name: "FmanUI", dependencies: ["FmanCore"]),
        .executableTarget(name: "fman", dependencies: ["FmanUI"]),
        .testTarget(name: "FmanCoreTests", dependencies: ["FmanCore"]),
        .testTarget(name: "FmanUITests", dependencies: ["FmanUI", "FmanCore"]),
    ],
    swiftLanguageModes: [.v5]
)
