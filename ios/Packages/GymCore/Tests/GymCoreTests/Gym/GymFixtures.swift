import Foundation
@testable import GymCore

/// A small library, its requirements and two gyms for the gym rules tests: Home (a flat bench and kettlebells of
/// 20 and 24 kg, the owner's real setup) and Iron (a commercial gym).
enum GymFixtures {
    static let kinds: [EquipmentKind] = [
        EquipmentKind(id: "dumbbells", name: "Dumbbells", category: .freeWeight, load: .fixedSet),
        EquipmentKind(id: "kettlebells", name: "Kettlebells", category: .freeWeight, load: .fixedSet),
        EquipmentKind(id: "barbell", name: "Barbell", category: .freeWeight, load: .plateLoaded),
        EquipmentKind(id: "flat-bench", name: "Flat bench", category: .bench, load: .none),
        EquipmentKind(id: "adjustable-bench", name: "Adjustable bench", category: .bench, load: .none),
        EquipmentKind(id: "incline-bench", name: "Incline bench", category: .bench, load: .none),
        EquipmentKind(id: "power-rack", name: "Power rack", category: .rack, load: .none),
        EquipmentKind(id: "bench-press-station", name: "Bench press station", category: .rack, load: .none),
        EquipmentKind(id: "pull-up-bar", name: "Pull-up bar", category: .rack, load: .bodyweight),
        EquipmentKind(id: "cable-station", name: "Cable station", category: .cable, load: .stack),
        EquipmentKind(id: "lat-pulldown", name: "Lat pulldown", category: .cable, load: .stack),
        EquipmentKind(id: "chest-press-machine", name: "Chest press", category: .machine, load: .stack),
        EquipmentKind(id: "pec-deck", name: "Pec deck", category: .machine, load: .stack),
        EquipmentKind(id: "leg-press", name: "Leg press", category: .machine, load: .plateLoaded),
    ]

    private static func ex(_ id: String, _ name: String, _ bodyPart: String, _ equipment: String, _ target: String,
                           _ secondary: [String] = []) -> Exercise {
        Exercise(id: id, name: name, bodyPart: bodyPart, equipment: equipment, target: target, secondary: secondary)
    }

    static let exercises: [Exercise] = [
        ex("c-bb-bench", "Barbell Bench Press", "chest", "barbell", "pectorals", ["triceps", "shoulders"]),
        ex("c-db-press", "Dumbbell Bench Press", "chest", "dumbbell", "pectorals", ["triceps", "shoulders"]),
        ex("c-db-incline", "Dumbbell Incline Press", "chest", "dumbbell", "pectorals", ["triceps", "shoulders"]),
        ex("c-machine-press", "Lever Chest Press", "chest", "leverage machine", "pectorals", ["triceps"]),
        ex("c-pec-deck", "Lever Seated Fly", "chest", "leverage machine", "pectorals"),
        ex("c-cable-fly", "Cable Middle Fly", "chest", "cable", "pectorals", ["shoulders"]),
        ex("c-cable-crossover", "Cable Crossover", "chest", "cable", "pectorals", ["shoulders"]),
        ex("c-cable-press", "Cable Standing Chest Press", "chest", "cable", "pectorals", ["triceps"]),
        ex("c-pushup", "Push-Up", "chest", "body weight", "pectorals", ["triceps"]),
        ex("b-pulldown", "Cable Pulldown", "back", "cable", "lats", ["biceps"]),
        ex("b-pullup", "Pull-Up", "back", "body weight", "lats", ["biceps"]),
        ex("b-db-row", "Dumbbell Row", "back", "dumbbell", "upper back", ["lats", "biceps"]),
        ex("b-kb-row", "Kettlebell One Arm Row", "back", "kettlebell", "upper back", ["lats", "biceps"]),
        ex("b-bb-row", "Barbell Row", "back", "barbell", "upper back", ["lats"]),
        ex("a-db-curl", "Dumbbell Curl", "upper arms", "dumbbell", "biceps", ["forearms"]),
        ex("a-kb-curl", "Kettlebell Hammer Curl", "upper arms", "kettlebell", "biceps", ["forearms"]),
        ex("a-cable-pushdown", "Cable Pushdown", "upper arms", "cable", "triceps"),
        ex("a-kb-skull", "Kettlebell Skull Crusher", "upper arms", "kettlebell", "triceps"),
        ex("l-leg-press", "Sled 45° Leg Press", "upper legs", "sled machine", "quads", ["glutes", "hamstrings"]),
        ex("x-shrug", "Lever Shrug", "back", "leverage machine", "traps"),
    ]

    static let requirements = ExerciseRequirements(groups: [
        "c-bb-bench": [["barbell"], ["flat-bench", "adjustable-bench", "bench-press-station"],
                       ["power-rack", "bench-press-station"]],
        "c-db-press": [["dumbbells"], ["flat-bench", "adjustable-bench"]],
        "c-db-incline": [["dumbbells"], ["adjustable-bench", "incline-bench"]],
        "c-machine-press": [["chest-press-machine"]],
        "c-pec-deck": [["pec-deck"]],
        "c-cable-fly": [["cable-station"]],
        "c-cable-crossover": [["cable-station"]],
        "c-cable-press": [["cable-station"]],
        "c-pushup": [],
        "b-pulldown": [["lat-pulldown", "cable-station"]],
        "b-pullup": [["pull-up-bar", "power-rack"]],
        "b-db-row": [["dumbbells"], ["flat-bench", "adjustable-bench"]],
        "b-kb-row": [["kettlebells"]],
        "b-bb-row": [["barbell"]],
        "a-db-curl": [["dumbbells"]],
        "a-kb-curl": [["kettlebells"]],
        "a-cable-pushdown": [["cable-station"]],
        "a-kb-skull": [["kettlebells"], ["flat-bench", "adjustable-bench"]],
        "l-leg-press": [["leg-press"]],
        // "x-shrug" is deliberately unmapped.
    ])

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    static let homeKettlebells = InventoryListing(id: id(1), kindId: "kettlebells", loads: .fixed(kg: [20, 24]),
                                                  isOwn: true)
    static let homeBench = InventoryListing(id: id(2), kindId: "flat-bench", isOwn: true)
    static let home = GymInventory(gymName: "Home", listings: [homeKettlebells, homeBench])

    static let iron = GymInventory(gymName: "Iron Works Gym", listings: [
        InventoryListing(id: id(10), kindId: "barbell", loads: .plates, confirmCount: 9),
        InventoryListing(id: id(11), kindId: "bench-press-station", confirmCount: 6),
        InventoryListing(id: id(12), kindId: "power-rack", confirmCount: 4),
        InventoryListing(id: id(13), kindId: "dumbbells", loads: .fixed(kg: [5, 10, 15, 20, 25, 30]), confirmCount: 8),
        InventoryListing(id: id(14), kindId: "adjustable-bench", confirmCount: 5),
        InventoryListing(id: id(15), kindId: "cable-station", loads: .stack(maxKg: 90, stepKg: 4.5), confirmCount: 7),
        InventoryListing(id: id(16), kindId: "lat-pulldown", loads: .stack(maxKg: 136, stepKg: 4.5), confirmCount: 7),
        InventoryListing(id: id(17), kindId: "chest-press-machine", loads: .stack(maxKg: 113, stepKg: 4.5),
                         confirmCount: 3),
        InventoryListing(id: id(18), kindId: "pec-deck", loads: .stack(maxKg: 90, stepKg: 4.5), confirmCount: 2),
        InventoryListing(id: id(19), kindId: "leg-press", loads: .plates, confirmCount: 3),
    ])

    static func matcher(_ inventory: GymInventory) -> InventoryMatcher {
        InventoryMatcher(requirements: requirements, kinds: kinds, inventory: inventory)
    }

    /// A finished workout on `day` (days since 1970, noon UTC) with these exercises.
    static func workout(day: Int, _ exerciseIds: [String]) -> Workout {
        let start = Date(timeIntervalSince1970: Double(day) * 86_400 + 43_200)
        return Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: "Day \(day)",
                       entries: exerciseIds.map { WorkoutEntry(exerciseId: $0) })
    }

    static func date(day: Int) -> Date { Date(timeIntervalSince1970: Double(day) * 86_400 + 36_000) }
}
