import Foundation
import GymCore

/// Where sync talks to, decided at launch.
enum SyncBackend: Equatable {
    /// No auth, no network: the default for `-uiTesting`, so UI tests stay hermetic.
    case disabled
    /// The Supabase project from Info.plist (in DEBUG, `SUPABASE_URL`/`SUPABASE_ANON_KEY` env vars win).
    case configured
    /// DEBUG/UI-test only (`-uiTesting -uiTestingBackend local`): like `configured`, but the auth session is kept
    /// in a test-only store that `-resetStore` wipes, so a relaunch can simulate a fresh install.
    case uiTestLocal
    /// DEBUG/UI-test only (`-seedConflict`): an in-process fake server that reports the first pushed workout as
    /// edited on another device, for the conflict UI (no auth, no network).
    case seededConflict
}

/// Launch arguments used by UI tests and debug runs.
struct LaunchOptions {
    /// In-memory store (fresh every launch).
    let inMemory: Bool
    /// Seed the owner's split if the store is empty.
    let seedOwner: Bool
    /// Fixed "now" for deterministic UI tests (ISO 8601), e.g. -fixedNow 2026-09-26T09:00:00Z
    let fixedNow: Date?
    /// UI tests that relaunch need a store that survives the process: -diskStore uses a file in tmp.
    let diskStoreURL: URL?
    /// Delete the disk store before opening (first launch of a test).
    let resetStore: Bool
    /// DEBUG/UI-test only (`-seedHistory`): seeds the owner's past workouts, for Log/History/progression tests.
    let seedHistory: Bool
    /// DEBUG/UI-test only: seeds 5 weekly weigh-ins (81.0 → 81.8 kg) ending on `fixedNow`, for
    /// screenshots and manual QA of the Body tab's chart and trend with real data.
    let seedBodyweight: Bool
    /// DEBUG/UI-test only: seeds one extra workout with a timed (plank) set, for testing the
    /// detail screen's time-mode display/edit without disturbing `-seedHistory`'s fixed shape.
    let seedPlank: Bool
    /// DEBUG/UI-test only: seeds `largeHistoryCount` synthetic workouts, for testing Log's pagination and for
    /// scroll performance (`-seedLargeHistory -largeHistoryCount 150`).
    let seedLargeHistory: Bool
    /// DEBUG only: `-largeHistoryCount N` (default 60, clamped to 1…1000).
    let largeHistoryCount: Int
    /// DEBUG/UI-test only (`-seedProposal`): inserts a pending Claude proposal (knee-break style) on the seeded
    /// routines, for the proposal review UI tests.
    let seedProposal: Bool
    /// DEBUG/UI-test only (`-seedTodayProposal`): a pending proposal that adds "Home · KB Upper" and picks it for
    /// today (`today` change), for the one-off-session UI test.
    let seedTodayProposal: Bool
    /// DEBUG/UI-test only (`-seedInsights`): six weeks of split workouts ending this Friday, for the recovery
    /// map, weekly sets and streak screens (`DebugInsightsSeed`).
    let seedInsights: Bool
    /// DEBUG/UI-test only (`-seedStrength`): sex/birth year on the profile, a weigh-in and squat/bench/deadlift
    /// sessions, for the strength-level screens (`DebugStrengthSeed`).
    let seedStrength: Bool
    /// DEBUG/UI-test only (`-forgetSession`): drops the stored auth session but keeps the local data, like a
    /// session revoked elsewhere.
    let forgetSession: Bool
    /// Where sync talks to (see `SyncBackend`).
    let syncBackend: SyncBackend
    /// DEBUG only: `GYM_SIMULATE_OFFLINE=1` in the environment makes every sync request fail as offline.
    let simulateOffline: Bool
    /// The process environment (DEBUG builds read the Supabase URL/key overrides from it).
    let environment: [String: String]
    /// `-uiTesting`: also used to default onboarding to already-complete, so the existing app UI test suite
    /// (which doesn't expect the onboarding flow) keeps working.
    let uiTesting: Bool
    /// `-onboarding`: forces the onboarding flow even under `-uiTesting`.
    let forceOnboarding: Bool
    /// `-skipOnboarding`: marks onboarding complete without forcing it off (same effect as `-uiTesting` alone).
    let skipOnboarding: Bool
    /// DEBUG/UI-test only (`-uiTesting -uiTestingPhotos`): exercises show locally drawn stand-in photos instead of the
    /// body-part illustration, so the photo UI can be tested without the network. Plain `-uiTesting` shows none.
    let uiTestingPhotos: Bool
    #if DEBUG
    /// `-importFixture`: the onboarding/Settings CSV import step uses the bundled sample CSV
    /// (`ImportFixture.csv`) instead of presenting `.fileImporter`, since XCUITest can't drive the Files UI
    /// reliably. DEBUG-only; never available in a Release build.
    let importFixture: Bool
    /// `-importFixture <source>` (`fitbod`, `strong`, `hevy`, `fitNotes`): which sample export to use; Fitbod when
    /// no (or an unknown) value follows.
    let importFixtureSource: ImportSource
    #endif
    /// DEBUG/UI-test only (`-seedGym`): a private "Home" gym with kettlebells (20 and 24 kg) and a flat bench, set as the
    /// current gym, no photos (`DebugGymSeed`).
    let seedGym: Bool
    /// DEBUG/UI-test only (`-gymPhotoFixture`): the gym photo screen's Library button uses a generated image instead of
    /// presenting the photo picker, which XCUITest can't drive.
    let gymPhotoFixture: Bool
    /// DEBUG/UI-test only (`-fakeLocation <lat>,<lng>`): where the phone is, with location permission treated as granted.
    let fakeLocation: (latitude: Double, longitude: Double)?
    /// DEBUG/UI-test only (`-fakeGymPlaces`): Maps search returns "Iron Works Gym" and "Test Fitness" (ids
    /// `fake-iron-works`, `fake-test-fitness`), 50 m and 2 km from the fake location.
    let fakeGymPlaces: Bool
    /// DEBUG/UI-test only (`-fakeGymCatalog`): the shared gym catalogue is an in-memory fake with fixed listings for
    /// "Iron Works Gym", and that gym is seeded as the current gym (`DebugSharedGymSeed`).
    let fakeGymCatalog: Bool
    /// DEBUG/UI-test only (`-fakeSignedIn`): the sharing screens treat the phone as signed in, so a report or a
    /// confirmation is queued and sent to the fake catalogue. Nothing else about the session changes.
    let fakeSignedIn: Bool
    /// DEBUG/UI-test only (`-fakeHealth`): Apple Health is an in-memory `FakeHealthStore` seeded with three Withings
    /// weigh-ins, so the Health flows can be tested on the simulator without HealthKit.
    let fakeHealth: Bool
    /// DEBUG/UI-test only (`-workoutStartedMinutesAgo N`): new workouts start N minutes before "now", so a workout
    /// finished under `-fixedNow` has a duration (and a calorie estimate).
    let workoutStartedMinutesAgo: Double?

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        inMemory = arguments.contains("-uiTesting")
        uiTesting = arguments.contains("-uiTesting")
        forceOnboarding = arguments.contains("-onboarding")
        skipOnboarding = arguments.contains("-skipOnboarding")
        #if DEBUG
        importFixture = arguments.contains("-importFixture")
        importFixtureSource = arguments.firstIndex(of: "-importFixture")
            .flatMap { arguments.indices.contains($0 + 1) ? ImportSource(rawValue: arguments[$0 + 1]) : nil } ?? .fitbod
        uiTestingPhotos = arguments.contains("-uiTestingPhotos")
        #else
        uiTestingPhotos = false
        #endif
        #if DEBUG
        // `-noSeed` simulates a fresh install of a real user (sync UI tests pull everything from the server).
        // `-emptyStore` is the same "skip every seed" behavior, named for Task 5's first-run empty-state tests.
        seedOwner = (arguments.contains("-uiTesting") || arguments.contains("-seedOwner"))
            && !arguments.contains("-noSeed") && !arguments.contains("-emptyStore")
        syncBackend = Self.backend(arguments)
        simulateOffline = environment["GYM_SIMULATE_OFFLINE"] == "1"
        #else
        seedOwner = false
        syncBackend = .configured
        simulateOffline = false
        #endif
        self.environment = environment
        fixedNow = arguments.firstIndex(of: "-fixedNow")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
            .flatMap { ISO8601DateFormatter().date(from: $0) }
        diskStoreURL = arguments.contains("-diskStore")
            ? FileManager.default.temporaryDirectory.appendingPathComponent("gymrollins-uitest.store") : nil
        resetStore = arguments.contains("-resetStore")
        #if DEBUG
        forgetSession = arguments.contains("-forgetSession")
        fakeHealth = arguments.contains("-fakeHealth")
        workoutStartedMinutesAgo = arguments.firstIndex(of: "-workoutStartedMinutesAgo")
            .flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil }
            .map { min(max($0, 0), 600) }
        seedProposal = arguments.contains("-seedProposal")
        seedTodayProposal = arguments.contains("-seedTodayProposal")
        seedInsights = arguments.contains("-seedInsights")
        seedStrength = arguments.contains("-seedStrength")
        seedGym = arguments.contains("-seedGym")
        gymPhotoFixture = arguments.contains("-gymPhotoFixture")
        fakeLocation = Self.coordinate(after: "-fakeLocation", in: arguments)
        fakeGymPlaces = arguments.contains("-fakeGymPlaces")
        fakeGymCatalog = arguments.contains("-fakeGymCatalog")
        fakeSignedIn = arguments.contains("-fakeSignedIn")
        seedHistory = arguments.contains("-seedHistory")
        seedBodyweight = arguments.contains("-seedBodyweight")
        seedPlank = arguments.contains("-seedPlank")
        seedLargeHistory = arguments.contains("-seedLargeHistory")
        largeHistoryCount = arguments.firstIndex(of: "-largeHistoryCount")
            .flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil }
            .map { min(max($0, 1), 1_000) } ?? 60
        #else
        forgetSession = false
        fakeHealth = false
        workoutStartedMinutesAgo = nil
        seedProposal = false
        seedTodayProposal = false
        seedInsights = false
        seedStrength = false
        seedGym = false
        gymPhotoFixture = false
        fakeLocation = nil
        fakeGymPlaces = false
        fakeGymCatalog = false
        fakeSignedIn = false
        seedHistory = false
        seedBodyweight = false
        seedPlank = false
        seedLargeHistory = false
        largeHistoryCount = 60
        #endif
    }

    #if DEBUG
    /// "<lat>,<lng>" after `flag`; nil when missing or out of range.
    private static func coordinate(after flag: String, in arguments: [String]) -> (latitude: Double, longitude: Double)? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        let parts = arguments[index + 1].split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, abs(parts[0]) <= 90, abs(parts[1]) <= 180 else { return nil }
        return (parts[0], parts[1])
    }

    private static func backend(_ arguments: [String]) -> SyncBackend {
        if arguments.contains("-seedConflict") { return .seededConflict }
        guard arguments.contains("-uiTesting") else { return .configured }
        let local = arguments.firstIndex(of: "-uiTestingBackend")
            .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } == "local"
        return local ? .uiTestLocal : .disabled
    }
    #endif
}
