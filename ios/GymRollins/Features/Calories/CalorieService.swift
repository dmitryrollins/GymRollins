import Foundation
import GymCore
import GymData
import os

/// Calorie estimates for the UI and Apple Health: the bundled Compendium table (`met-values.json`), the exercise
/// library and the latest weigh-in before each workout (plan 15).
@MainActor
final class CalorieService {
    let table: METTable?
    var library: () -> ExerciseLibrary
    private let body: BodyRepository
    /// Weigh-ins, loaded on first use after each `invalidate()`.
    private var samples: [BodyWeightSample]?
    private static let log = Logger(subsystem: "com.rollins.gymrollins", category: "calories")

    init(table: METTable? = CalorieService.loadTable(), library: @escaping () -> ExerciseLibrary, body: BodyRepository) {
        self.table = table
        self.library = library
        self.body = body
    }

    static func loadTable(bundle: Bundle = .main) -> METTable? {
        guard let url = bundle.url(forResource: "met-values", withExtension: "json") else {
            log.fault("met-values.json missing from the bundle")
            return nil
        }
        do { return try METTable.decode(Data(contentsOf: url)) } catch {
            log.fault("met-values.json unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Weigh-ins changed (or the store was wiped).
    func invalidate() { samples = nil }

    func estimate(_ workout: Workout) -> CalorieEstimate? {
        guard let table else { return nil }
        let library = library()
        let weight = BodyWeightPicker.weightKg(at: workout.startedAt, samples: bodySamples())
        return CalorieEstimator.estimate(workout: workout, exercise: library.exercise, bodyWeightKg: weight,
                                         table: table)
    }

    /// Estimated kcal of the workouts that started in the ISO week (Mon–Sun) containing `date`.
    func weekTotal(of workouts: [Workout], containing date: Date,
                   calendar: Calendar = Calendar(identifier: .iso8601)) -> Int {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return 0 }
        return workouts.filter { week.contains($0.startedAt) }.compactMap(estimate).reduce(0) { $0 + $1.kcal }
    }

    private func bodySamples() -> [BodyWeightSample] {
        if let samples { return samples }
        let loaded: [BodyWeightSample]
        do {
            loaded = try body.entries(since: nil).map { BodyWeightSample(date: $0.date, weightKg: $0.weightKg) }
        } catch {
            Self.log.error("Load weigh-ins failed: \(error.localizedDescription, privacy: .public)")
            loaded = []
        }
        samples = loaded
        return loaded
    }
}
