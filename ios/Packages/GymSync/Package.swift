// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GymSync",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "GymSync", targets: ["GymSync"])],
    dependencies: [
        .package(path: "../GymCore"),
        .package(path: "../GymData"),
    ],
    targets: [
        .target(name: "GymSync", dependencies: ["GymCore", "GymData"]),
        .testTarget(name: "GymSyncTests", dependencies: ["GymSync", "GymCore", "GymData"]),
        // Against a throwaway local Worker (scripts/test-sync-integration.sh); each suite skips itself without API_URL.
        .testTarget(name: "GymSyncIntegrationTests", dependencies: ["GymSync", "GymCore", "GymData"]),
    ]
)
