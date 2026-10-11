import Foundation

// Settings' Data section: full-data JSON backup and Fitbod-format CSV export.
extension AppEnvironment {
    func exportService() -> ExportService {
        let library = self.library
        return ExportService(profiles: profiles, routines: routines, workouts: workouts, body: body,
                             customExercises: customExercises, proposals: proposals,
                             exerciseName: { library.exercise($0)?.name ?? $0 }, now: now,
                             muscleTargets: muscleTargets, exercisePreferences: exercisePrefs)
    }
}
