import CoreGraphics
import Foundation
import GymCore
import GymData

/// What the share screen shows for one workout.
struct ShareWorkoutModel: Identifiable {
    let id = UUID()
    let url: URL?
    let qrCode: CGImage?
    let leftOutNotice: String?
    /// Why there's no link: your own exercises, or nothing in the workout yet.
    let nothingMessage: String
    let cutOffNotice: String?

    var nothingToSend: Bool { url == nil }

    static func make(sources: [SharedWorkout.Source], library: ExerciseLibrary, link: WorkoutLink) -> ShareWorkoutModel {
        let draft = SharedWorkout.make(from: sources)
        let url = draft.workout.flatMap(link.url(for:))
        let names = draft.leftOutIds.map { DisplayName.of(library.exercise($0)?.name ?? $0) }
        return ShareWorkoutModel(url: url, qrCode: url.flatMap { QRCodeImage.make($0.absoluteString) },
                                 leftOutNotice: leftOutNotice(names, nothingLeft: url == nil),
                                 nothingMessage: draft.leftOutIds.isEmpty ? "There's nothing to share yet."
                                     : "These are your own exercises, so they can't go in a link.",
                                 cutOffNotice: draft.cutOffCount > 0
                                     ? "Only the first \(DomainLimits.routineExercisesMax) exercises are in this link." : nil)
    }

    private static func leftOutNotice(_ names: [String], nothingLeft: Bool) -> String? {
        guard !names.isEmpty, !nothingLeft else { return nil }
        let list = names.joined(separator: ", ")
        return names.count == 1 ? "Left out, because it's your own exercise: \(list)"
            : "Left out, because they're your own exercises: \(list)"
    }
}
