import SwiftUI

/// Settings → Hidden exercises: every exercise marked "Don't recommend again", each with "Show Again" (back to normal).
struct HiddenExercisesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var error: String?

    var body: some View {
        let hidden = env.hiddenExercises()
        List {
            if let error {
                Text(error).foregroundStyle(Theme.destructive)
            }
            if hidden.isEmpty {
                Text("No hidden exercises. Choose \u{201C}Don\u{2019}t recommend again\u{201D} in an exercise\u{2019}s "
                     + "\u{00B7}\u{00B7}\u{00B7} menu to stop it being suggested.")
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("hidden.empty")
            }
            ForEach(hidden, id: \.id) { item in
                HStack {
                    Text(item.name).foregroundStyle(Theme.textPrimary)
                        .accessibilityIdentifier("hidden.name.\(item.id)")
                    Spacer()
                    Button("Show Again") { showAgain(item.id) }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                        .accessibilityLabel("Show \(item.name) again")
                        .accessibilityIdentifier("hidden.show.\(item.id)")
                }
                .frame(minHeight: Theme.minTapSize)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Hidden Exercises")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func showAgain(_ id: String) {
        do {
            try env.setPreference(.normal, for: id)
            error = nil
        } catch {
            AppEnvironment.log.error("Show exercise again failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't update that. Try again."
        }
    }
}
