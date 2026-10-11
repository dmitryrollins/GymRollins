import GymCore
import SwiftUI

/// Asks for the two optional inputs strength levels need: sex and birth year. Saved on the profile (synced);
/// "Remove" clears both.
struct StrengthProfileSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var sex: ProfileSex = .male
    @State private var birthYear = 1990
    @State private var loaded = false
    @State private var error: String?

    /// Gregorian birth years for ages 14–100 (whatever the device calendar).
    private var years: [Int] { StrengthReport.birthYears(now: env.now(), calendar: .current) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Sex", selection: $sex) {
                        ForEach(ProfileSex.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("strength.profile.sex")
                    Picker("Birth year", selection: $birthYear) {
                        ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                    }
                    .accessibilityIdentifier("strength.profile.birthYear")
                } footer: {
                    Text(StrengthText.privacy + " Stored with your profile; Claude sees only the resulting levels.")
                }
                if let error {
                    Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("strength.profile.error")
                }
                if env.profile.sex != nil || env.profile.birthYear != nil {
                    Button("Remove sex and birth year", role: .destructive) { save(sex: nil, birthYear: nil) }
                        .accessibilityIdentifier("strength.profile.remove")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Compare Your Lifts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("strength.profile.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(sex: sex, birthYear: birthYear) }
                        .accessibilityIdentifier("strength.profile.save")
                }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded else { return }
        if let s = env.profile.sex { sex = s }
        if let y = env.profile.birthYear, years.contains(y) { birthYear = y }
        loaded = true
    }

    private func save(sex: ProfileSex?, birthYear: Int?) {
        do {
            try env.setStrengthProfile(sex: sex, birthYear: birthYear)
            error = nil
            dismiss()
        } catch {
            AppEnvironment.log.error("Save strength profile failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't save. Try again."
        }
    }
}
