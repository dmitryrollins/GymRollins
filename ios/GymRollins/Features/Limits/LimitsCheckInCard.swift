import SwiftUI

/// The check-in card on Today. `LimitsReminder` owns the model and runs the actions.
struct LimitsCheckInCard: View {
    @Binding var model: LimitsCheckInModel
    let note: String
    let until: Date?
    let dates: ClosedRange<Date>
    let yes: () -> Void
    let notYet: () -> Void
    let saveDate: () -> Void
    let resume: (LimitsCheckInModel.PausedRoutine) -> Void
    let openPlan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
            if let error = model.error {
                Text(error).font(.footnote).foregroundStyle(Theme.destructive)
                    .accessibilityIdentifier("limits.error")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("limits.card")
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .asking: asking
        case .choosingDate: choosingDate
        case .resuming: resuming(message: nil)
        case .resumed(let message): resuming(message: message)
        case .done: EmptyView()
        }
    }

    private var asking: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note).font(.headline).foregroundStyle(Theme.textPrimary)
                .accessibilityIdentifier("limits.card.note")
            if let until {
                Text(LimitsCheckInModel.question(until: until)).font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("limits.question")
            }
            PrimaryGlassButton(title: "Yes, continue", identifier: "limits.yes", action: yes)
            SecondaryGlassButton(title: "Not yet", identifier: "limits.notYet", action: notYet)
        }
    }

    private var choosingDate: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask me again on").font(.headline).foregroundStyle(Theme.textPrimary)
            DatePicker("Ask me again on", selection: $model.nextDate, in: dates, displayedComponents: .date)
                .labelsHidden()
                .tint(Theme.accent)
                .frame(minHeight: Theme.minTapSize)
                .accessibilityIdentifier("limits.nextDate")
            PrimaryGlassButton(title: "Save", identifier: "limits.saveDate", action: saveDate)
            SecondaryGlassButton(title: "Cancel", identifier: "limits.cancelDate") { model.cancelLater() }
        }
    }

    private func resuming(message: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message {
                Text(message).font(.subheadline).foregroundStyle(Theme.textPrimary)
                    .accessibilityIdentifier("limits.resumed")
                PrimaryGlassButton(title: "Open My Plan", identifier: "limits.openPlan", action: openPlan)
            } else {
                Text("Start light: bring a paused workout back at 60% of its weights.")
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("limits.resumeIntro")
            }
            ForEach(Array(model.paused.enumerated()), id: \.element.id) { index, routine in
                SecondaryGlassButton(title: "Resume \(routine.name) at 60%", identifier: "limits.resume.\(index)") {
                    resume(routine)
                }
            }
            SecondaryGlassButton(title: message == nil ? "Not now" : "Done",
                                 identifier: message == nil ? "limits.notNow" : "limits.done") { model.close() }
        }
    }
}
