import Foundation

/// The text after the link's `#`: `1.0001_3_8-10.1512_3_10_g1.0300_1_s600`. The first field is the version, then one field
/// per exercise: id, sets, target (`10`, `8-10` or `s600`), and an optional superset (`g1`). Only letters, digits and `_ - .`,
/// so chat apps keep it in the link.
public extension SharedWorkout {
    static let linkVersion = 1
    static let maxLinkLength = 1024

    enum Decoded: Equatable, Sendable {
        case valid(SharedWorkout, droppedUnknown: Int)
        case damaged
        case tooNew
    }

    var linkText: String {
        ([String(Self.linkVersion)] + items.map(Self.field)).joined(separator: ".")
    }

    /// The link is untrusted: any broken syntax or value outside the limits makes the whole of it damaged. An exercise this
    /// phone doesn't have is only dropped and counted, because a newer app can have exercises an older one lacks.
    static func decode(_ text: String, isKnown: (String) -> Bool) -> Decoded {
        guard text.utf8.count <= maxLinkLength else { return .damaged }
        let fields = text.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = fields.first, let version = number(first), version >= 1 else { return .damaged }
        guard version == linkVersion else { return .tooNew }
        let itemFields = fields.dropFirst()
        guard (1...DomainLimits.routineExercisesMax).contains(itemFields.count) else { return .damaged }
        let parsed = itemFields.map(item)
        guard parsed.allSatisfy({ $0 != nil }) else { return .damaged }
        let all = parsed.compactMap { $0 }
        guard Set(all.map(\.exerciseId)).count == all.count else { return .damaged }
        let known = all.filter { isKnown($0.exerciseId) }
        guard !known.isEmpty else { return .damaged }
        return .valid(SharedWorkout(items: known), droppedUnknown: all.count - known.count)
    }

    private static func field(_ item: Item) -> String {
        let target: String
        switch item.target {
        case .reps(let low?, let high): target = "\(low)-\(high)"
        case .reps(nil, let high): target = "\(high)"
        case let .seconds(seconds): target = "s\(seconds)"
        }
        let parts = [item.exerciseId, "\(item.sets)", target] + (item.superset.map { ["g\($0)"] } ?? [])
        return parts.joined(separator: "_")
    }

    private static func item(_ field: Substring) -> Item? {
        let parts = field.split(separator: "_", omittingEmptySubsequences: false)
        guard (3...4).contains(parts.count), isShareableId(parts[0]),
              let sets = number(parts[1]), PlanChangeLimits.sets.contains(sets),
              let target = target(parts[2]) else { return nil }
        let exerciseId = String(parts[0])
        guard parts.count == 4 else { return Item(exerciseId: exerciseId, sets: sets, target: target) }
        guard parts[3].hasPrefix("g"), let superset = number(parts[3].dropFirst()),
              (1...DomainLimits.routineExercisesMax).contains(superset) else { return nil }
        return Item(exerciseId: exerciseId, sets: sets, target: target, superset: superset)
    }

    private static func target(_ text: Substring) -> Target? {
        if text.hasPrefix("s") {
            guard let seconds = number(text.dropFirst()), PlanChangeLimits.sec.contains(seconds) else { return nil }
            return .seconds(seconds)
        }
        let bounds = text.split(separator: "-", omittingEmptySubsequences: false).map(number)
        switch bounds.count {
        case 1:
            guard let reps = bounds[0], PlanChangeLimits.reps.contains(reps) else { return nil }
            return .reps(min: nil, max: reps)
        case 2:
            guard let low = bounds[0], let high = bounds[1], PlanChangeLimits.reps.contains(low),
                  PlanChangeLimits.reps.contains(high), low <= high else { return nil }
            return .reps(min: low, max: high)
        default:
            return nil
        }
    }

    /// ASCII digits only, in their shortest form, so each value has one spelling.
    private static func number(_ text: Substring) -> Int? {
        let bytes = Array(text.utf8)
        guard (1...6).contains(bytes.count), bytes.allSatisfy({ (48...57).contains($0) }),
              bytes.count == 1 || bytes[0] != 48 else { return nil }
        return Int(text)
    }
}
