// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FMServerBar",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "FMServerBar", path: "Sources/FMServerBar"),
        .testTarget(name: "FMServerBarTests", dependencies: ["FMServerBar"], path: "Tests/FMServerBarTests"),
    ]
)
