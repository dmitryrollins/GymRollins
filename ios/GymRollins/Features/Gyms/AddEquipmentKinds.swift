import GymCore

extension AddEquipmentModel {
    /// A group of kind tiles on step 2.
    struct KindSection: Identifiable, Equatable {
        let title: String
        let kinds: [EquipmentKind]
        var id: String { title }
    }

    private static let commonMachines = [
        "lat-pulldown", "leg-press", "chest-press-machine", "pec-deck", "seated-row-machine", "leg-curl",
    ]
    private static let commonFreeWeights = [
        "dumbbells", "kettlebells", "barbell", "adjustable-bench", "power-rack", "cable-station",
    ]

    /// The common kinds in two groups first, then every other kind by category, so all of them stay reachable.
    static func kindSections(_ catalog: GymEquipmentCatalog) -> [KindSection] {
        let common = Set(commonMachines + commonFreeWeights)
        let leading = [("Machines", commonMachines), ("Free weights \u{00B7} benches \u{00B7} racks", commonFreeWeights)]
            .map { KindSection(title: $0.0, kinds: $0.1.compactMap(catalog.kind)) }
        let rest = catalog.kinds.filter { !common.contains($0.id) }
        let more = EquipmentCategory.allCases.compactMap { category -> KindSection? in
            let members = rest.filter { $0.category == category }
            return members.isEmpty ? nil : KindSection(title: "More \u{00B7} \(title(category))", kinds: members)
        }
        return leading.filter { !$0.kinds.isEmpty } + more
    }

    private static func title(_ category: EquipmentCategory) -> String {
        switch category {
        case .machine: "machines"
        case .cable: "cables"
        case .freeWeight: "free weights"
        case .bench: "benches"
        case .rack: "racks"
        case .cardio: "cardio"
        case .accessory: "accessories"
        }
    }
}
