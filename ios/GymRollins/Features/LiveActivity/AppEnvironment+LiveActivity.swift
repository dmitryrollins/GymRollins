import Foundation

extension AppEnvironment {
    /// What the workout Live Activity should show now (nil: no workout in progress, or it is finished).
    var liveActivitySnapshot: WorkoutActivitySnapshot? {
        let library = self.library
        return WorkoutActivitySnapshot.make(session: session, now: now(), unit: profile.unit,
                                            exercise: { library.exercise($0) })
    }

    /// A Live Activity button, applied to the in-progress workout (ignored when it no longer applies).
    func performActivityAction(_ action: WorkoutActivityAction) {
        let library = self.library
        guard let session else {
            Self.log.notice("Live Activity action ignored: no workout in progress")
            return
        }
        if !session.perform(action, exercise: { library.exercise($0) }) {
            Self.log.notice("Live Activity action ignored: it no longer applies")
        }
    }
}
