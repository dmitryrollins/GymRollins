import Foundation
import GymCore

/// The bundled equipment kinds and the equipment each exercise needs: what the picker offers and the rules run on.
struct GymEquipmentCatalog: Sendable {
    /// A section of the kind picker.
    struct Group: Identifiable, Equatable {
        let title: String
        let kinds: [EquipmentKind]
        var id: String { title }
    }

    let kinds: [EquipmentKind]
    let requirements: ExerciseRequirements

    /// Shown as big tiles first (spec: "big tiles for common kinds").
    static let commonKindIds = [
        "dumbbells", "barbell", "flat-bench", "adjustable-bench", "power-rack", "cable-station",
        "lat-pulldown", "chest-press-machine", "leg-press", "smith-machine", "pull-up-bar", "kettlebells",
    ]

    /// Nothing loaded: the rules see no kinds, so the app adapts nothing.
    static let unavailable = GymEquipmentCatalog(kinds: [], requirements: ExerciseRequirements(groups: [:]))

    /// False for `unavailable` (a catalog that failed to load).
    var isUsable: Bool { !kinds.isEmpty && !requirements.groups.isEmpty }

    static func load(bundle: Bundle = .main) throws -> GymEquipmentCatalog {
        guard let kindsURL = bundle.url(forResource: "equipment-kinds", withExtension: "json"),
              let requirementsURL = bundle.url(forResource: "equipment-requirements", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return GymEquipmentCatalog(kinds: try EquipmentKind.decodeList(Data(contentsOf: kindsURL)),
                                   requirements: try ExerciseRequirements.decode(Data(contentsOf: requirementsURL)))
    }

    func kind(_ id: String) -> EquipmentKind? { kinds.first { $0.id == id } }

    var commonTiles: [EquipmentKind] { Self.commonKindIds.compactMap(kind) }

    /// Kinds whose name contains every word typed, ignoring case; common ones first.
    func search(_ query: String) -> [EquipmentKind] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return commonFirst(kinds.filter { kind in
            let name = kind.name.lowercased()
            return words.allSatisfy { name.contains($0) }
        })
    }

    /// Machines and cables; free weights, benches and racks; cardio and accessories. Common kinds lead each group.
    var groups: [Group] {
        let sections: [(String, Set<EquipmentCategory>)] = [
            ("Machines", [.machine, .cable]),
            ("Free weights, benches and racks", [.freeWeight, .bench, .rack]),
            ("Cardio and accessories", [.cardio, .accessory]),
        ]
        return sections.compactMap { title, categories in
            let members = commonFirst(kinds.filter { categories.contains($0.category) })
            return members.isEmpty ? nil : Group(title: title, kinds: members)
        }
    }

    private func commonFirst(_ list: [EquipmentKind]) -> [EquipmentKind] {
        let order = Dictionary(uniqueKeysWithValues: Self.commonKindIds.enumerated().map { ($1, $0) })
        return list.enumerated().sorted { a, b in
            let ra = order[a.element.id] ?? Int.max, rb = order[b.element.id] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }
}
