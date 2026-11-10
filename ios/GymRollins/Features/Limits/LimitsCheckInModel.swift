import Foundation
import GymCore

/// The check-in card's steps and copy. A value: `LimitsReminder` runs the actions and reports what happened.
struct LimitsCheckInModel: Equatable {
    struct PausedRoutine: Equatable, Identifiable {
        let id: UUID
        let name: String
    }

    enum Step: Equatable {
        /// "Is it the right time to continue?"
        case asking
        /// Not yet: a new date to ask again on.
        case choosingDate
        /// Yes was saved: the paused routines that can come back.
        case resuming
        /// A routine came back; the text says how many exercises were lowered.
        case resumed(String)
        /// Answered and closed.
        case done
    }

    private(set) var step: Step = .asking
    /// The Not yet picker's date.
    var nextDate = Date.distantPast
    private(set) var paused: [PausedRoutine] = []
    private(set) var error: String?

    static let saveFailed = "Couldn't save. Try again."

    static func resumeFailed(_ name: String) -> String { "Couldn't bring \(name) back. Try again." }

    /// Today's reminder: the note, and its end date when it has one.
    static func reminder(note: String, until: Date?, calendar: Calendar = .current) -> String {
        guard let until else { return note }
        return "\(note) \u{00B7} until \(GoalDate.dayMonth(until, calendar: calendar))"
    }

    static func question(until: Date, calendar: Calendar = .current) -> String {
        "You planned this until \(GoalDate.dayMonth(until, calendar: calendar)). Is it the right time to continue?"
    }

    static func resumedMessage(name: String, lowered: Int) -> String {
        switch lowered {
        case 0: "\(name) is back. Pick its day in My Plan."
        case 1: "\(name) is back, with 1 exercise at 60%. Pick its day in My Plan."
        default: "\(name) is back, with \(lowered) exercises at 60%. Pick its day in My Plan."
        }
    }

    /// Whether the card shows. After Yes it stays until it's closed, though nothing is due any more.
    func showsCard(due: Bool, workoutRunning: Bool) -> Bool {
        switch step {
        case .resuming, .resumed: true
        case .asking, .choosingDate: due && !workoutRunning
        case .done: false
        }
    }

    mutating func askLater(now: Date, calendar: Calendar = .current) {
        nextDate = LimitsCheckIn.laterDate(now: now, calendar: calendar)
        step = .choosingDate
        error = nil
    }

    mutating func cancelLater() {
        step = .asking
        error = nil
    }

    /// Yes was saved: offer the paused routines, or close when there are none.
    mutating func cleared(paused routines: [PausedRoutine]) {
        paused = routines
        step = routines.isEmpty ? .done : .resuming
        error = nil
    }

    mutating func resumed(_ id: UUID, name: String, lowered: Int) {
        paused.removeAll { $0.id == id }
        step = .resumed(Self.resumedMessage(name: name, lowered: lowered))
        error = nil
    }

    /// A routine that was deleted or resumed elsewhere leaves the list.
    mutating func dropped(_ id: UUID) {
        paused.removeAll { $0.id == id }
        if paused.isEmpty, step == .resuming { step = .done }
    }

    mutating func close() {
        step = .done
        error = nil
    }

    mutating func failed(_ message: String) { error = message }
}
