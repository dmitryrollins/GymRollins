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
        // The Supabase-only suites left (proposals, Claude's grants) sign in with the Supabase client the app no
        // longer has. They stay as the reference plan 29 ports to the API, unbuilt meanwhile.
        .testTarget(name: "GymSyncIntegrationTests", dependencies: [
            "GymSync", "GymCore", "GymData",
            .product(name: "Supabase", package: "supabase-swift"),
        ], exclude: ["SupabaseParked"]),
    ]
)
