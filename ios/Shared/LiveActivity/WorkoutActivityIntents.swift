import AppIntents
import Foundation

// Buttons on the workout Live Activity. As `LiveActivityIntent`s they run in the app's process (launched in the
// background if needed), so they act on the same in-progress `WorkoutSession` the logging screen uses; the widget
// extension only uses these types to build its buttons. Ids travel as strings (App Intents parameter types).

/// Logs the next set with its planned weight and reps (no editing from the lock screen).
struct LogPlannedSetIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Log set"
    static let description = IntentDescription("Logs the next set of the current exercise with its planned values.")
    static let isDiscoverable = false

    @Parameter(title: "Workout") var workoutId: String
    @Parameter(title: "Exercise entry") var entryId: String
    @Parameter(title: "Set") var setId: String

    init() {}

    init(workoutId: UUID, entryId: UUID, setId: UUID) {
        self.workoutId = workoutId.uuidString
        self.entryId = entryId.uuidString
        self.setId = setId.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let workout = UUID(uuidString: workoutId), let entry = UUID(uuidString: entryId),
           let set = UUID(uuidString: setId) {
            await WorkoutActivityIntentRouter.perform(.logPlannedSet(workoutId: workout, entryId: entry, setId: set))
        }
        return .result()
    }
}

/// Adds 30 seconds to the running rest.
struct ExtendRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Add 30 seconds of rest"
    static let isDiscoverable = false
    static let seconds: TimeInterval = 30

    @Parameter(title: "Workout") var workoutId: String
    @Parameter(title: "Exercise entry") var entryId: String?

    init() {}

    init(workoutId: UUID, entryId: UUID?) {
        self.workoutId = workoutId.uuidString
        self.entryId = entryId?.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let workout = UUID(uuidString: workoutId) {
            let entry = entryId.flatMap(UUID.init(uuidString:))
            await WorkoutActivityIntentRouter.perform(.extendRest(workoutId: workout, entryId: entry, seconds: Self.seconds))
        }
        return .result()
    }
}

/// Ends the running rest now.
struct SkipRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip rest"
    static let isDiscoverable = false

    @Parameter(title: "Workout") var workoutId: String
    @Parameter(title: "Exercise entry") var entryId: String?

    init() {}

    init(workoutId: UUID, entryId: UUID?) {
        self.workoutId = workoutId.uuidString
        self.entryId = entryId?.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let workout = UUID(uuidString: workoutId) {
            let entry = entryId.flatMap(UUID.init(uuidString:))
            await WorkoutActivityIntentRouter.perform(.skipRest(workoutId: workout, entryId: entry))
        }
        return .result()
    }
}
