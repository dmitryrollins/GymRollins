import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// Plan 07 review fixes: bar persisted from the plate inventory; onboarding weigh-in upsert.
@MainActor
@Suite struct ProfileBodyRepositoryTests {
    let container: ModelContainer
    let clock: () -> Date = { Date(timeIntervalSince1970: 1_790_000_000) }

    init() throws { container = try GymStore.container(inMemory: true) }

    /// The bar is persisted from the plate inventory (the thing the plate calculator uses), so a kg inventory
    /// saved alongside a stale lb `barKg` still reloads with a 20 kg bar.
    @Test func barIsPersistedFromThePlateInventory() throws {
        let repo = ProfileRepository(context: container.mainContext, now: clock)
        try repo.save(Profile(unit: .kg, plateInventory: .standardKg)) // default barKg is 45 lb
        let loaded = try repo.load()
        #expect(loaded.barKg == 20)
        #expect(loaded.plateInventory.bar == 20)
        let load = PlateCalculator.load(targetKg: 60, inventory: loaded.plateInventory)
        #expect(load.perSide == [20])
        #expect(load.remainder == 0)
    }

    /// `upsert` of an existing id updates that weigh-in in place (the onboarding weigh-in is re-saved on revisit).
    @Test func bodyweightUpsertUpdatesExistingEntry() throws {
        let repo = BodyRepository(context: container.mainContext, now: clock)
        let id = UUID()
        try repo.upsert(BodyweightEntry(id: id, date: clock(), weightKg: 81))
        try repo.upsert(BodyweightEntry(id: id, date: clock().addingTimeInterval(60), weightKg: 82.5))
        let all = try repo.entries(since: nil)
        #expect(all.count == 1)
        #expect(all.first?.id == id)
        #expect(all.first?.weightKg == 82.5)
        #expect(try container.mainContext.fetch(FetchDescriptor<BodyweightRecord>()).count == 1)
    }
}
