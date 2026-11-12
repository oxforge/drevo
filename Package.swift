// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "drevo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "drevo", targets: ["drevo"]),
    ],
    targets: [
        .target(name: "DrevoCore"),
        .target(name: "DrevoUI", dependencies: ["DrevoCore"]),
        .executableTarget(name: "drevo", dependencies: ["DrevoUI"]),
        .testTarget(name: "DrevoCoreTests", dependencies: ["DrevoCore"]),
        .testTarget(name: "DrevoUITests", dependencies: ["DrevoUI", "DrevoCore"]),
    ],
    swiftLanguageModes: [.v5]
)
