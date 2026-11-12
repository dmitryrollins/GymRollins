import Foundation
import GymCore

/// Typing in one box of the exercise screen, from its first keystroke until the box is left. The edit starts from a
/// snapshot of the sets as they were then: the edited set and the later sets its value carries to (`SetCarry`: working
/// sets still to do whose same box showed the same text, in the unit shown), worked out once. Every keystroke is
/// written from that snapshot, so a value passed on the way ("1" on the way to "12") never counts as set by hand, and
/// text that doesn't parse (a cleared box, ".") puts the sets back as they were.
struct SetEdit {
    let field: SetField
    /// What the box shows while it is edited: the text as typed.
    let text: String
    /// The edited set, then the sets that follow it, as they were before the first keystroke.
    private let snapshot: [WorkoutSet]
    private let unit: WeightUnit

    /// Starts an edit of `field` from `sets` as they are now; nil when its set isn't among them.
    init?(field: SetField, sets: [WorkoutSet], unit: WeightUnit) {
        guard let edited = sets.first(where: { $0.id == field.setId }) else { return nil }
        let shown = { (set: WorkoutSet) in SetFieldFormat.display(field.on(setId: set.id), set: set, unit: unit) }
        let followers = Set(SetCarry.following(sets, edited: edited.id, value: shown))
        self.init(field: field, text: shown(edited), snapshot: [edited] + sets.filter { followers.contains($0.id) },
                  unit: unit)
    }

    private init(field: SetField, text: String, snapshot: [WorkoutSet], unit: WeightUnit) {
        self.field = field
        self.text = text
        self.snapshot = snapshot
        self.unit = unit
    }

    /// The edit with `text` typed in the box.
    func typing(_ text: String) -> SetEdit { SetEdit(field: field, text: text, snapshot: snapshot, unit: unit) }

    /// What the text does to the sets, as one change: each set of the snapshot takes its box's value from the text
    /// applied to its snapshot copy (`SetFieldFormat.applying`, so minutes, seconds and distance stay consistent), or
    /// from the snapshot copy itself when the text doesn't parse. Only that box's values are written, so anything else
    /// that changed meanwhile (a rating, a set logged from the watch) stays, and a follower logged meanwhile is left
    /// alone.
    var changes: [UUID: (WorkoutSet) -> WorkoutSet] {
        Dictionary(uniqueKeysWithValues: snapshot.map { before in
            let box = field.on(setId: before.id)
            let after = SetFieldFormat.applying(text, to: box, set: before, unit: unit) ?? before
            let isFollower = before.id != field.setId
            return (before.id, { current in
                isFollower && current.done ? current : SetFieldFormat.copying(box, from: after, to: current)
            })
        })
    }
}
