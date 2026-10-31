import Foundation
import GymCore
import Testing
@testable import GymRollins

@MainActor
@Suite struct GymEquipmentCatalogTests {
    private func catalog() throws -> GymEquipmentCatalog { try GymEquipmentCatalog.load() }

    @Test func loadsBundledFiles() throws {
        let catalog = try catalog()
        #expect(catalog.kinds.count == 46)
        #expect(catalog.requirements.groups.count == 1_107)
        #expect(catalog.isUsable)
        #expect(!GymEquipmentCatalog.unavailable.isUsable)
    }

    /// The picker's two leading sections hold real kinds, all of them (the add flow shows `kindSections`).
    @Test func kindSectionTilesAreRealKinds() throws {
        let catalog = try catalog()
        let sections = AddEquipmentModel.kindSections(catalog)
        #expect(sections.prefix(2).map(\.kinds.count) == [6, 6])
    }

    @Test func searchMatchesNameAndIgnoresCase() throws {
        let catalog = try catalog()
        #expect(catalog.search("PRESS").map(\.id).contains("leg-press"))
        #expect(catalog.search("curl").contains { $0.id == "ez-bar" })
        #expect(catalog.search("  ").isEmpty)
        #expect(catalog.search("zzzz").isEmpty)
        #expect(catalog.search("bench press").map(\.id) == ["bench-press-station"])
    }

    @Test func kindSectionsKeepCommonFirstAndEveryKindOnce() throws {
        let catalog = try catalog()
        let sections = AddEquipmentModel.kindSections(catalog)
        #expect(sections.prefix(2).map(\.title) == ["Machines", "Free weights \u{00B7} benches \u{00B7} racks"])
        #expect(sections.dropFirst(2).allSatisfy { $0.title.hasPrefix("More \u{00B7} ") })
        let ids = sections.flatMap(\.kinds).map(\.id)
        #expect(ids.count == catalog.kinds.count)
        #expect(Set(ids) == Set(catalog.kinds.map(\.id)), "nothing is lost, nothing is listed twice")
        #expect(sections[0].kinds.first?.id == "lat-pulldown")
        #expect(sections[1].kinds.first?.id == "dumbbells")
    }
}
