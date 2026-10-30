import Foundation
import GymCore
import Testing
@testable import GymRollins

@Suite struct GymEquipmentCatalogTests {
    private func catalog() throws -> GymEquipmentCatalog { try GymEquipmentCatalog.load() }

    @Test func loadsBundledFiles() throws {
        let catalog = try catalog()
        #expect(catalog.kinds.count == 46)
        #expect(catalog.requirements.groups.count == 1_107)
        #expect(catalog.isUsable)
        #expect(!GymEquipmentCatalog.unavailable.isUsable)
    }

    @Test func commonTilesAreRealKinds() throws {
        let catalog = try catalog()
        #expect(catalog.commonTiles.count == GymEquipmentCatalog.commonKindIds.count)
        #expect(catalog.commonTiles.map(\.id) == GymEquipmentCatalog.commonKindIds)
    }

    @Test func searchMatchesNameAndIgnoresCase() throws {
        let catalog = try catalog()
        #expect(catalog.search("PRESS").map(\.id).contains("leg-press"))
        #expect(catalog.search("curl").contains { $0.id == "ez-bar" })
        #expect(catalog.search("  ").isEmpty)
        #expect(catalog.search("zzzz").isEmpty)
        #expect(catalog.search("bench press").map(\.id) == ["bench-press-station"])
    }

    @Test func groupsKeepCommonFirst() throws {
        let catalog = try catalog()
        let groups = catalog.groups
        #expect(groups.map(\.title) == ["Machines", "Free weights, benches and racks", "Cardio and accessories"])
        #expect(groups.flatMap(\.kinds).count == catalog.kinds.count)
        let free = try #require(groups.first { $0.title.hasPrefix("Free weights") })
        #expect(free.kinds.prefix(3).map(\.id) == ["dumbbells", "barbell", "flat-bench"])
        let machines = try #require(groups.first { $0.title == "Machines" })
        #expect(machines.kinds.first?.id == "cable-station")
    }
}
