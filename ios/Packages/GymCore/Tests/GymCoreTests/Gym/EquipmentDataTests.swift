import Foundation
import Testing
@testable import GymCore

/// The bundled equipment data (`ios/GymRollins/Resources/equipment-*.json`) decodes and fits the exercise library.
@Suite struct EquipmentDataTests {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("GymRollins/Resources")

    private func load(_ name: String) throws -> Data {
        try Data(contentsOf: Self.resources.appendingPathComponent(name))
    }

    @Test func kindsDecodeWithUniqueIds() throws {
        let kinds = try EquipmentKind.decodeList(load("equipment-kinds.json"))
        #expect(kinds.count >= 40)
        #expect(Set(kinds.map(\.id)).count == kinds.count)
        #expect(kinds.first { $0.id == "kettlebells" }?.load == .fixedSet)
        #expect(kinds.first { $0.id == "leg-press" }?.isMachine == true)
        #expect(kinds.first { $0.id == "dumbbells" }?.isMachine == false)
    }

    @Test func requirementsNameKnownKindsAndLibraryExercises() throws {
        let kinds = Set(try EquipmentKind.decodeList(load("equipment-kinds.json")).map(\.id))
        let requirements = try ExerciseRequirements.decode(load("equipment-requirements.json"))
        let library = Set(try JSONDecoder().decode([Exercise].self, from: load("exercises.json")).map(\.id))
        #expect(requirements.groups.count >= 1_000)
        #expect(Set(requirements.groups.flatMap { $0.value.flatMap { $0 } }).isSubset(of: kinds))
        #expect(Set(requirements.groups.keys).isSubset(of: library))
        #expect(requirements.groups.values.allSatisfy { $0.allSatisfy { !$0.isEmpty } })
    }
}
