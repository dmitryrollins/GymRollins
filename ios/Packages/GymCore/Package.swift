// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GymCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "GymCore", targets: ["GymCore"])],
    targets: [
        .target(name: "GymCore"),
        .testTarget(name: "GymCoreTests", dependencies: ["GymCore"]),
    ]
)
