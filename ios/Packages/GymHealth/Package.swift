// swift-tools-version: 6.2
import PackageDescription

// Apple Health layer (plan 15): the `HealthStore` seam, the HealthKit implementation (iOS/watchOS only), a fake for
// tests and UI tests, and the sync logic. Depends on GymCore + GymData, and GymWatchLink for the plan-17 rules that
// keep one Health workout when the Apple Watch records it (the watchOS 10 app itself links only GymWatchLink).
let package = Package(
    name: "GymHealth",
    platforms: [.iOS(.v26), .macOS(.v26), .watchOS(.v26)],
    products: [.library(name: "GymHealth", targets: ["GymHealth"])],
    dependencies: [.package(path: "../GymCore"), .package(path: "../GymData"), .package(path: "../GymWatchLink")],
    targets: [
        .target(name: "GymHealth", dependencies: ["GymCore", "GymData", "GymWatchLink"]),
        .testTarget(name: "GymHealthTests", dependencies: ["GymHealth", "GymCore", "GymData", "GymWatchLink"]),
    ]
)
