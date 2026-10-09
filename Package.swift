// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Isle",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IsleCore", path: "Sources/IsleCore"),
        .executableTarget(name: "Isle", dependencies: ["IsleCore"], path: "Sources/Isle"),
        .testTarget(name: "IsleCoreTests", dependencies: ["IsleCore"], path: "Tests/IsleCoreTests"),
    ]
)
