// swift-tools-version: 6.2
import PackageDescription

// Phone <-> Apple Watch link (plan 17): the WatchConnectivity message types, the watch's view model, crown stepping
// and the single-Health-workout rules. Foundation only, so the watchOS 10 app (Apple Watch Series 5) can link it and
// its logic is tested on macOS.
let package = Package(
    name: "GymWatchLink",
    platforms: [.iOS(.v26), .macOS(.v26), .watchOS(.v10)],
    products: [.library(name: "GymWatchLink", targets: ["GymWatchLink"])],
    targets: [
        .target(name: "GymWatchLink"),
        .testTarget(name: "GymWatchLinkTests", dependencies: ["GymWatchLink"])
    ]
)
