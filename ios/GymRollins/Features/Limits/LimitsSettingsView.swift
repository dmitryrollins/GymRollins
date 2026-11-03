import GymCore
import GymData
import SwiftUI

/// Settings > Injuries / limits: change the note, set or clear its end date, or clear the note.
struct LimitsSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var hasDate = false
    @State private var until = Date()
    @State private var savedUntil: Date?
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LimitsEditor(note: $note, hasDate: $hasDate, until: $until, dates: dates, identifier: "limits.edit.note")
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.destructive)
                        .accessibilityIdentifier("limits.edit.error")
                }
                PrimaryGlassButton(title: "Save", identifier: "limits.edit.save") {
                    persist(note: note, until: hasDate ? until : nil)
                }
                if !env.profile.limits.isEmpty {
                    SecondaryGlassButton(title: "Clear note", identifier: "limits.edit.clear") {
                        persist(note: "", until: nil)
                    }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 16)
        }
        .background(Theme.background)
        .navigationTitle("Injuries / Limits")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
    }

    /// Tomorrow to a year ahead, reaching back to a saved date that has passed, so the picker can still show it.
    private var dates: ClosedRange<Date> {
        let allowed = LimitsCheckIn.allowedDates(now: env.now(), calendar: .current)
        return min(savedUntil ?? allowed.lowerBound, allowed.lowerBound)...allowed.upperBound
    }

    private func load() {
        guard !loaded else { return }
        note = env.profile.limits
        savedUntil = env.profile.limitsUntil
        hasDate = savedUntil != nil
        until = savedUntil ?? LimitsCheckIn.laterDate(now: env.now(), calendar: .current)
        loaded = true
    }

    private func persist(note: String, until: Date?) {
        do {
            try env.saveLimits(note, until: until.map { GoalDate.normalized($0) })
            error = nil
            dismiss()
        } catch GymDataError.invalidInput(let message) {
            error = message
        } catch {
            AppEnvironment.log.error("Save limits failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save. Try again."
        }
    }
}
