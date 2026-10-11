// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GymData",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "GymData", targets: ["GymData"])],
    dependencies: [.package(path: "../GymCore")],
    targets: [
        .target(name: "GymData", dependencies: ["GymCore"]),
        .testTarget(name: "GymDataTests", dependencies: ["GymData", "GymCore"]),
    ]
)
