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
}
