// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GymSync",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "GymSync", targets: ["GymSync"])],
    dependencies: [
        .package(path: "../GymCore"),
        .package(path: "../GymData"),
        .package(url: "https://github.com/supabase/supabase-swift", from: "2.55.0"),
    ],
    targets: [
        .target(name: "GymSync", dependencies: [
            "GymCore", "GymData",
            .product(name: "Supabase", package: "supabase-swift"),
        ]),
        .testTarget(name: "GymSyncTests", dependencies: [
            "GymSync", "GymCore", "GymData",
            .product(name: "Supabase", package: "supabase-swift"),
        ]),
        .testTarget(name: "GymSyncIntegrationTests", dependencies: [
            "GymSync", "GymCore", "GymData",
            .product(name: "Supabase", package: "supabase-swift"),
        ]),
    ]
)
