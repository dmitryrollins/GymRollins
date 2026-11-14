import Foundation
import GymCore

/// A weight the plate calculator can show: one run of neighbouring sets of the same kind and weight ("Sets 1–3").
struct PlateTarget: Equatable, Identifiable {
    /// "warmup.1" / "working.2": the kind and the number of the run's first set. Also its chip's accessibility id.
    let id: String
    /// "Warm-up 1", "Warm-ups 1–2", "Set 1", "Sets 1–3".
    let title: String
    let weightKg: Double
    let setIds: [UUID]
}

/// Which weights the plate calculator offers for an exercise's sets, and which one it opens on.
enum PlateTargets {
    /// Two weights closer than this are the same weight.
    private static let sameWeightKg = 0.001

    /// One target per run of neighbouring sets of the same kind and weight, in set order.
    static func targets(for sets: [WorkoutSet]) -> [PlateTarget] {
        let ordinals = SetOrdinal.ordinals(for: sets)
        var runs: [[Int]] = []
        for index in sets.indices {
            if let previous = runs.last?.last, sets[previous].warmup == sets[index].warmup,
               abs(sets[previous].weightKg - sets[index].weightKg) < sameWeightKg {
                runs[runs.count - 1].append(index)
            } else {
                runs.append([index])
            }
        }
        return runs.map { run in target(run.map { sets[$0] }, first: ordinals[run[0]]) }
    }

    /// The set the owner is on: the one being typed in, else the first set not done, else the last set.
    static func current(in targets: [PlateTarget], sets: [WorkoutSet], editing: UUID?) -> PlateTarget? {
        let editingId = sets.first { $0.id == editing }?.id
        guard let setId = editingId ?? sets.first(where: { !$0.done })?.id else { return targets.last }
        return targets.first { $0.setIds.contains(setId) } ?? targets.last
    }

    private static func target(_ run: [WorkoutSet], first: SetOrdinal) -> PlateTarget {
        let (kind, name, number) = switch first {
        case .warmup(let number): ("warmup", "Warm-up", number)
        case .working(let number): ("working", "Set", number)
        }
        let title = run.count == 1 ? "\(name) \(number)" : "\(name)s \(number)–\(number + run.count - 1)"
        return PlateTarget(id: "\(kind).\(number)", title: title, weightKg: run[0].weightKg, setIds: run.map(\.id))
    }
}
