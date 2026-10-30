import GymCore
import SwiftUI

/// One exercise on Today: thumbnail, name, today's sets summary, an "Edited" badge once its sets were changed for
/// today, and the `···` menu. Tapping it opens the exercise screen in plan mode (`onOpen`); while a workout runs the
/// row is display only (`onOpen` nil).
struct TodayExerciseRow<MenuContent: View>: View {
    let row: TodayModel.Row
    let exercise: Exercise?
    let onOpen: (() -> Void)?
    @ViewBuilder let menu: () -> MenuContent

    var body: some View {
        Group {
            if let onOpen {
                Button(action: onOpen) { content }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens today's sets")
            } else {
                content
            }
        }
        .accessibilityIdentifier(identifier)
        .overlay(alignment: .trailing) { if onOpen != nil { menu() } }
    }

    private var content: some View {
        ExerciseRow(exercise: exercise, fallbackName: row.name, subtitle: row.subtitle, badge: badge, note: note,
                    photoFile: row.photoFile, trailingInset: onOpen != nil ? 36 : 0)
            .contentShape(.rect)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
    }

    /// A swapped row is found by `today.row.swapped.<exerciseId>`, since its note is part of the row's one element.
    private var identifier: String {
        if case .swapped = row.gymMark { return "today.row.swapped.\(row.exerciseId)" }
        return "today.row.\(row.exerciseId)"
    }

    private var note: String? {
        switch row.gymMark {
        case let .swapped(planned, missingKind): "for \(planned) \u{00B7} no \(missingKind) here"
        case .unavailable: "not available here"
        case nil: nil
        }
    }

    private var badge: Badge? {
        switch row.gymMark {
        case .swapped: return Badge(text: "SWAPPED", kind: .record)
        case .unavailable: return Badge(text: "NOT HERE", kind: .neutral)
        case nil: break
        }
        if row.setsEdited { return Badge(text: "Edited", kind: .success) }
        return row.badge.map { Badge(text: $0, kind: .success) }
    }
}

/// Today's per-exercise menu, shared by the Today row and the plan-mode exercise screen's `···`.
struct TodayExerciseMenuItems: View {
    let exerciseId: String
    let isEdited: Bool
    @Binding var confirmingNever: String?
    @Binding var error: String?
    let onDetails: () -> Void
    let onHistory: () -> Void
    let onReplace: () -> Void
    let onReset: () -> Void
    let onDelete: () -> Void
    /// "Use <planned> anyway" on a row the gym swapped: the planned exercise's name and what brings it back.
    var usePlanned: (name: String, action: () -> Void)?

    var body: some View {
        Button("Video & Instructions", systemImage: "play.rectangle", action: onDetails)
        Button("Exercise History", systemImage: "calendar", action: onHistory)
        Button("Replace", systemImage: "arrow.left.arrow.right", action: onReplace)
        if let usePlanned {
            Button("Use \(usePlanned.name) anyway", systemImage: "arrow.uturn.backward.circle", action: usePlanned.action)
                .accessibilityIdentifier("today.menu.usePlanned")
        }
        if isEdited {
            Button("Reset to Suggested", systemImage: "arrow.uturn.backward", action: onReset)
                .accessibilityIdentifier("today.menu.reset")
        }
        Divider()
        ExercisePreferenceMenuItems(exerciseId: exerciseId, confirmingNever: $confirmingNever, error: $error)
        Divider()
        Button("Delete from Workout", systemImage: "trash", role: .destructive, action: onDelete)
    }
}
