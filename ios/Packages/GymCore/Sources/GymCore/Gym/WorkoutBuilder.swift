import Foundation

/// One exercise of a built workout.
public struct BuiltItem: Sendable, Hashable {
    public let exercise: RoutineExercise
    public let match: InventoryMatch
    public let muscle: BuildMuscle
    /// Set when this repeats a recent exercise because nothing else fits: the day it was last done.
    public let repeatOf: Date?
    /// A no-equipment exercise that fills a slot after the equipment exercises ran out.
    public let isBodyweightFill: Bool
}

/// "Only N <muscle> items catalogued at <gym> so far."
public struct ThinInventoryNotice: Sendable, Hashable {
    public let muscle: BuildMuscle
    /// Active listings at the gym used by at least one equipment candidate for this muscle.
    public let itemCount: Int
}

/// The result of Build workout. It can be shorter than `requestedSlots`: slots that nothing fits are dropped, never
/// padded with equipment the gym doesn't have.
public struct BuiltWorkout: Sendable, Hashable {
    public let items: [BuiltItem]
    public let thin: [ThinInventoryNotice]
    public let requestedSlots: Int
}

/// Builds a workout for muscle chips from one gym's equipment (spec §5, "Build workout").
public struct WorkoutBuilder: Sendable {
    /// At most this many exercises on one machine listing (`EquipmentKind.isMachine`).
    public static let maxPerMachine = 2
    /// Exercises from this many of the latest workouts that trained a muscle are skipped for it.
    public static let recentWorkoutsPerMuscle = 3
    static let idNamespace = UUID(uuidString: "6A0F3C52-1B7E-4F0D-9C2A-3D5E7B9A1C40")!

    let matcher: InventoryMatcher
    let exercises: [Exercise]
    let byId: [String: Exercise]
    /// Newest first.
    let history: [Workout]
    let loggedCounts: [String: Int]
    let preferences: [String: ExercisePreference]

    public init(matcher: InventoryMatcher, exercises: [Exercise], history: [Workout],
                loggedCounts: [String: Int] = [:], preferences: [String: ExercisePreference] = [:]) {
        self.matcher = matcher
        self.exercises = exercises
        self.byId = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.history = history.sorted { $0.startedAt > $1.startedAt }
        self.loggedCounts = loggedCounts
        self.preferences = preferences
    }

    /// Fills the slots round-robin across the chips with equipment exercises, then fills what's left with
    /// no-equipment exercises. Thin-inventory notices are for chips that had slots no equipment exercise fit.
    public func build(_ request: BuildRequest) -> BuiltWorkout {
        guard !request.muscles.isEmpty else { return BuiltWorkout(items: [], thin: [], requestedSlots: 0) }
        let day = StableHash.day(of: request.date)
        let total = request.length.slots(muscleCount: request.muscles.count)
        let pools = Dictionary(uniqueKeysWithValues: request.muscles.map { ($0, pool(for: $0, day: day)) })
        var picker = SlotPicker(matcher: matcher, avoid: request.avoid)
        var unfilled: [BuildMuscle: Int] = [:]
        for slot in 0..<total {
            let muscle = request.muscles[slot % request.muscles.count]
            guard let pool = pools[muscle] else { continue }
            if !picker.pick(from: pool.equipment, recent: pool.recent, muscle: muscle, fill: false) {
                unfilled[muscle, default: 0] += 1
            }
        }
        let thin = request.muscles.compactMap { muscle -> ThinInventoryNotice? in
            guard unfilled[muscle, default: 0] > 0, let pool = pools[muscle] else { return nil }
            return ThinInventoryNotice(muscle: muscle, itemCount: Set(pool.equipment.flatMap(\.match.listingIds)).count)
        }
        for muscle in request.muscles {
            guard let pool = pools[muscle] else { continue }
            for _ in 0..<unfilled[muscle, default: 0] {
                _ = picker.pick(from: pool.bodyweight, recent: pool.recent, muscle: muscle, fill: true)
            }
        }
        let items = Self.ordered(picker.picked).map { item(from: $0, day: day) }
        return BuiltWorkout(items: items, thin: thin, requestedSlots: total)
    }

    /// Exercises that train two or more muscle groups first, then the rest, then bodyweight fills; otherwise the
    /// order they were picked in (round-robin across the chips).
    static func ordered(_ picks: [SlotPicker.Pick]) -> [SlotPicker.Pick] {
        func rank(_ pick: SlotPicker.Pick) -> Int { pick.isFill ? 2 : (pick.candidate.compound ? 0 : 1) }
        return picks.enumerated()
            .sorted { a, b in rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset }
            .map(\.element)
    }

    /// The default sets and reps for the exercise's equipment, no planned weight (progression and `AvailableLoads`
    /// set it later), and an id that is the same for the same day and exercise.
    private func item(from pick: SlotPicker.Pick, day: Int) -> BuiltItem {
        let exercise = pick.candidate.exercise
        let defaults = RoutineExercise.defaults(exerciseId: exercise.id, mode: exercise.mode,
                                                barbell: exercise.isBarbellLoaded)
        let planned = RoutineExercise(id: StableUUID.make(namespace: Self.idNamespace, name: "\(day)|\(exercise.id)"),
                                      exerciseId: exercise.id, sets: defaults.sets, reps: defaults.reps,
                                      repsMin: defaults.repsMin, sec: defaults.sec, mode: defaults.mode,
                                      policy: defaults.policy, incKg: defaults.incKg)
        return BuiltItem(exercise: planned, match: pick.candidate.match, muscle: pick.muscle, repeatOf: pick.repeatOf,
                         isBodyweightFill: pick.isFill)
    }
}
